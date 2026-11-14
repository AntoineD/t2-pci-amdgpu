# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Stabilizes AMD GPU initialization on Apple T2 Intel Macs running Linux. The GPU fails to init reliably because Apple's ACPI tables lack power-resource methods the `amdgpu` driver expects, causing the PCI link to come up in an undefined state. The fix applies five ordered layers during boot: ACPI override → modprobe options → udev power pinning → PCI remove/rescan warmfix → display manager ordering.

Target hardware: iMac20,2 (i7-10700K + Navi10 / Radeon Pro 5700 XT). Should work on other T2 Macs with AMD GPUs.

## Architecture — boot sequence layers

The layers must execute in this order; each depends on the previous:

1. **ACPI SSDT** (`GFXALT-multi.dsl` → `.aml`): Injects `_PR3`/`_DSM` stubs into GPU device across four possible ACPI paths (`PEG0/EGP0/EGP1`, `PEG0/PEGP`, `RP05.PEGP`, `RP21.PEGP`). Packed into `/boot/acpi_override.img` as an early initrd cpio, loaded via `early_initrd=acpi_override.img` in `/boot/grub2/grubenv` (from `GRUB_EARLY_INITRD_LINUX_CUSTOM`). Uses `CondRefOf` to match the right path at boot.
   The cpio **must be uncompressed**: `acpi_table_upgrade()` scans the raw initrd before decompression, so a gzipped archive is skipped without any error. Installers before 2026-10 gzipped it, and no journaled boot on iMac20,2 (2026-08-24 onward) ever loaded the table. Proof it loaded is an `ACPI: SSDT … (v02 LH GFXALT …)` line in `journalctl -k -b`. The old `dmesg | grep "Early table override"` check matched a message current kernels no longer print, so it could never confirm anything. `install.sh` rebuilds a gzip image (magic `1f8b`) even when it is newer than the `.aml`.

2. **modprobe.d** (`amdgpu.conf`): Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level, blacklists `radeon`, and sets `snd_hda_intel.power_save_controller=0`. Duplicates GRUB cmdline params intentionally — survives rescue boots that bypass GRUB.
   **The cold-probe cause, and its fix:** `amdgpu-navi10-imac.conf` sets `options amdgpu ppfeaturemask=0xfff7bffd`. The installer adds it only for Navi 10 iMac20,x GPUs, matched on device and Apple subsystem IDs: `1002:731B`/`106B:021A` (Radeon Pro 5700, this machine) and `1002:7319`/`106B:021B` (5700 XT).
   It is the default `0xfff7bfff` with `PP_MCLK_DPM_MASK` (`0x2`) cleared, so the SMU's init request leaves out DPM_UCLK, MEM_VDDCI_SCALING and MEM_MVDD_SCALING. On these boards the SMU hangs on that request: `EnableAllSmuFeatures`, msg 6, `SMU: No response`, after a 3.2 s poll. Without the mask, 18 of 29 power-off boots failed (with restarts depending on the previous boot); with it, 9 of 9 power-off boots probed cleanly on 2026-10-17, gdm 8.81–9.00 s against ~14.8 s on a reset boot.
   Clearing `0x4` (PCIe DPM) instead did nothing. The module option rides in the initramfs (modprobe.d), so it applies to the cold probe with no GRUB change.
   Trade-off: memory clock DPM is off, so the memory clock cannot scale up. Under `auto` the core still scales (300–1350 MHz); `pp_dpm_mclk` then reads `S: 0Mhz *`, and `amdgpu_pm_info` shows `0 MHz (MCLK)`, since the SMU no longer reports it.
   Re-enabling the three bits at runtime (`echo 0x00000662a3d9afbb > pp_features`) is accepted, but it is not worth it. The UCLK table stays one 98 MHz level, and idle power rose from 11.4 W to 17.0 W. Sources: omarchy PR #10169, t2linux/kernel#27, t2linux/wiki#743 (the same `DPM_UCLK` hang on the 5300).
   The driver-level mask costs more than the kernel fix would. Clearing `PP_MCLK_DPM_MASK` makes amdgpu build a one-level UCLK table, so memory stays at its boot clock under `auto` as well. On the 5300 (iMac20,1, `1002:7340`/`106B:0219`), wiki#743 instead cleared only `FEATURE_DPM_UCLK_BIT` (`0x08`) in the SMU's allowed mask, by kernel patch. There the re-enable through `pp_features` restored real levels (98/500/625/875 MHz), and Counter-Strike went from "substantially below normal" to 300+ FPS. Kernel patches that defer only UCLK: `0001-amdgpu-fix-smu-problem.patch` in that thread (10/10 boots), and t2linux/linux-t2-patches#60 and #61 (#61 added `7319/021B`, not this machine's `731B/021A`, and closed unmerged). Prefer such a kernel over the mask once one ships.
   The display-before-SMU order may cure the hang on its own. On 7.2.9, edschofield saw 13 of 20 warm boots fail with SMU first (the upstream order) and 40 of 40 pass with patch 7003's display-first order. The order comes from OCLP, which sets DC register `0x4F1` at boot. That is the `imac5k_table` quirk that 7.2.9-310.t2 shipped without its `{}` terminator (see layer 4). Once a t2 kernel ships it intact, test several power-off boots **without** `amdgpu-navi10-imac.conf`. If they all pass, retire the mask and memory-clock DPM comes back.
   The warmfix stays as the safety net and now normally logs "cold probe already succeeded".
   Before this was found, a reset before the first probe was tried. Its findings, in case it comes back:
   - only `nomodeset` stops the probe; `amdgpu.modeset=0` no longer does on 7.2;
   - the t2 kernel's patch 2009 adds a vga_switcheroo probe deferral to amdgpu;
   - a bus reset of `.0` is refused while `.1` exists;
   - a cold GPU's PSP sign-of-life (`C2PMSG_81`) reads 0, which is why amdgpu never resets on its first probe.
   Neither `amdgpu.aspm=0` nor `pcie_aspm=off` turns ASPM off on the GPU link. `amdgpu.aspm=0` only skips amdgpu's own ASPM setup, and `pcie_aspm=off` leaves firmware's configuration alone. Apple's firmware enables L1: `lspci -vv` shows `ASPM L1 Enabled` on 00:01.0, 01:00.0, 02:00.0 and 03:00.0. It also enables L1 on NVMe, T2 and Ethernet; only the Thunderbolt chain has it off. Turning it off for real does not cure the cold-probe failure. Tested 2026-10-17 with `pcie_aspm.policy=performance`, which works here because the kernel skips `_OSC` on Apple and assumes PCIe control (`OS assumes control of [...]`). lspci confirmed `ASPM Disabled` on every GPU link, and the cold probe still failed with `SMU: No response msg_reg: 6`. Dropping `pcie_aspm=off` saves no power either: with `CONFIG_PCIEASPM_DEFAULT=y` the kernel keeps firmware's settings.

3. **udev rules**:
   - `99-amdgpu-t2.rules`: Pins `power/control=on` for AMD VGA (class `0x030000`) and HDMI audio (class `0x040300`) at device bind, before the driver claims the device. Also sets the DPM level after the driver loads: `T2_GPU_DPM` from `/etc/t2-pci-amdgpu.conf` via `IMPORT{file}`, `low` when the file is missing or the value is not `low`/`auto`/`high`. `t2-gpu-dpm.sh` writes that file and applies the level live. udev's parser skips `#` lines and strips quotes, but a trailing comment becomes part of the value (so it falls back to `low`); the last line for a key wins. `t2-gpu-dpm.sh saved` reads it the same way, and `amdgpu-check.sh` compares it with the live level. `low` came from the t2linux hybrid-graphics guide (MacBook dGPUs, "thermal crashes"). Measured on iMac20,2 2026-10-17 with glmark2 terrain at 2560×1440: `auto` idles exactly like `low` (10 W, 42 °C); under load it ran 45 W at 1350 MHz and 176–181 FPS vs 23 W and 125 FPS, and after 5 min the junction was at 66 °C and rising ~1 °C/30 s (critical 105 °C). The rule also records amdgpu's `bind` uevent as `AMDGPU_WARMFIX_BOUND=1`, the warmfix's signal that the probe returned success.
     The audio write is best-effort: `snd_hda_intel` calls `pm_runtime_allow()` from async probe work and resets the attribute to `auto` after udev has run, so no udev rule can win that race. `power_save_controller=0` is what actually keeps that function awake — `azx_runtime_idle()` then returns `-EBUSY`, so `power/control` still reads `auto` but nothing acts on it. Verify with `runtime_status`, not `control`. tuned undoes the option: its `[audio]` plugin defaults to `reset_controller=true` (tuned 2.28) and writes `power_save_controller=Y` when a profile with an `[audio]` section loads (stock `balanced` and `powersave`), ~12 s into boot. `install.sh` therefore shadows each such profile with a same-name `/etc/tuned/profiles/<name>/tuned.conf` (from `t2-tuned-hda.conf.in`) that includes the stock one and sets only `reset_controller=false`; the include resolves to `/usr/lib` because tuned skips files it has already loaded, and the merge keeps the stock `timeout`. Files carry a first-line marker; a same-name profile without it is the user's, and `install.sh` keeps it and warns only when `t2-tuned-audio.sh` finds it still resets the value.
   - `99-t2-usb.rules`: Pins `power/control=on` for USB root hubs (`idVendor=0x1d6b`, hub class `0x09`). T2 xHCI hubs autosuspend aggressively and silently stop reporting device-attach events on suspended ports — symptom is plugged devices missing from `lsusb` with no kernel log entry.

4. **Warmfix service** (`amdgpu-warmfix.service` → runs generated `amdgpu-pci-reset-load.sh`): Oneshot before display-manager. Waits for amdgpu's coldplug probe of the VGA function to settle; if the GPU's *own* render node (`<pci dev>/drm/renderD*`) then exists the cold probe succeeded and the reset is skipped. Never test the global `/dev/dri/renderD*`: i915 on an iGPU-enabled MacBookPro or an eGPU publishes there too and would mask a dead dGPU. Otherwise removes GPU PCI functions (.1 audio first, then .0 VGA), rescans bus, waits up to 20s for that render node. Retries once on failure. Skips only when `nomodeset` is on the cmdline without an `amdgpu.modeset` override (triggering conditions `|!nomodeset` and `|amdgpu.modeset`). `amdgpu.modeset` is "Override nomodeset (1 = enable, -1 = auto)", and its only check is `drm_firmware_drivers_only() && amdgpu_modeset == -1`. So any value given, `0` included, re-enables the probe, and `amdgpu.modeset=0` alone disables nothing. The unit and the installer used to treat it as "amdgpu off": the warmfix skipped itself while amdgpu still probed. An override set in modprobe.d instead of the cmdline is not seen by the condition. `Environment=AMDGPU_WARMFIX_ALWAYS_RESET=1` in a drop-in forces the reset every boot; only the exact value `1` does (`0`/`false` leave the skip on).
   Never write `remove` while `amdgpu_pci_probe()` is in flight: the write blocks on the device lock, then lands on the failing probe's cleanup path and oopses in `vcn_v2_0_sw_fini` on VCN state the unwind already freed — on iMac20,2, a boot wedged at the splash on 3 of 4 boots. The `driver` symlink cannot gate this, because `driver_sysfs_add()` creates it *before* the probe runs. Settled means DRM nodes under the PCI device (probe succeeded), or no `driver` symlink *and* amdgpu's module is `live` *and* the device is not on the deferred-probe list (failed and unbound). No symlink alone is not enough: a probe that has not started looks identical. On T2 the cold probe is normally *deferred* — amdgpu returns `-EPROBE_DEFER` via `vga_switcheroo_client_probe_defer()` until `apple_gmux` binds, then re-runs from `deferred_probe_work_func` — and with no udev-settle nothing orders the warmfix after gmux. The deferred list is `/sys/kernel/debug/devices_deferred`; without debugfs the script falls back to "ACPI `APP000B` present and no driver bound to its PNP node" (`APP000B:*/physical_node/driver`). Not `/sys/module/apple_gmux/initstate`: a built-in gmux has no such file, which read as deferred forever and cost a 60 s wait plus a failed unit. DRM nodes are not a hard end-of-probe signal either (`drm_dev_register()` precedes xcp/kfd/fbdev setup, which can still fail under the lock), so the settled state must hold for 1.5 s before a `remove`. The wait's deadlines run on `/proc/uptime` (read without a fork), not on a poll count: 600 polls with their forks drifted past the nominal 60 s. That wait cost 1.5–2.0 s on every boot, so end signals from outside sysfs shorten it. *Bound*: udev processed the `bind` uevent, which `driver_bound()` sends only after the probe returned 0; `99-amdgpu-t2.rules` records it as `AMDGPU_WARMFIX_BOUND=1` and clears it on `unbind` (udev keeps recorded properties across later events, so a stale record would pass a rebind's running probe for a finished one), and the wait ends at once. Never use udev's `DRIVER=` for this: `really_probe()` sets `dev->driver` before the probe runs, so any uevent during the probe carries it. *Fbdev*: the kernel logged `[drm] fbN: … frame buffer device` for this function, which also ends the wait at once. `amdgpu_pci_probe()` sets up fbdev after every step that can fail it; only debugfs (a failure is logged, not returned) and runtime PM (off, `runpm=0`) follow before `return 0`. It beats the bind record by ~0.86 s at boot (fbdev line at 8.475 s, bind seen at 9.337 s: udev is busy with amdgpu's child devices), and it survives switch-root, which the bind record does not. No fbdev device appears in sysfs on this kernel (only `fbcon`), so the kernel log is the only place to see it. *Failed*: the kernel logged `probe with driver amdgpu failed`. Both kernel-log signals count only when they are the last probe event logged for the function: every probe past the vga_switcheroo deferral logs `initializing kernel modesetting` first, so an earlier probe's lines (before a rescan or a rebind) are superseded. The window before a new probe logs its start is covered by also requiring the settled state. A failure still needs ~0.5 s of settled state: the line comes before `driver_sysfs_remove()` and the devres teardown, which run under the device lock (amdgpu's `ttm finalized` landed 25 ms after the line). The warmfix logs which signal ended the wait; `(no end signal seen)` means it fell back to the full ~1.5 s.
   Known gap: every reset boot loses HDMI/DP audio. The re-probe's PSP mode1 reset wipes `.1`'s config space (BAR0 reads 0 while the kernel still has it assigned), and amdgpu restores only `.0`. `snd_hda_intel` then fails with `CORB reset timeout … CORBRP = 65535` / "GPU sound probed, but not operational". **Do not fix this by removing `.1` again and rescanning after the reset.** Tried 2026-10-17 (reverted). On 7.2.8 a `remove` of a device whose HDA probe failed this way leaks its IRQ handler: `remove_proc_entry: removing non-empty directory 'irq/NN', leaking at least 'snd_hda_intel:cardN'`, on 6 of 6 boots. The fresh probe then oopsed in `azx_probe_work` on 2 of those 6 (`snd_dma_alloc_dir_pages`, `snd_hdac_bus_stop_cmd_io`, list-poison addresses). That wedged sound, gdm and shutdown, and needed a hard reset. Removing `.1` by hand on a booted system worked once, so it is the at-boot timing that loses. A safe fix must keep `snd_hda_intel` off `.1` until after the mode1 reset, not remove a failed card.
   A probe that never settles aborts the unit (exit 1) instead of removing anyway. On 7.2.9-310.t2 the probe worker oopses every boot and dies holding the device lock; the old "proceeding anyway" `remove` then sat in D state forever, unkillable, holding the display manager ~7 min. The wait shortens to 15s once `/proc/sys/kernel/tainted` has bit 128 (oops).
   That kernel's cause: a new iMac20,x DMI quirk, `imac5k_table`, which registers the display IP block before SMU and lacks its `{}` terminator. Check any kernel's module with `nm -S amdgpu.ko | grep imac5k_table` (decompress the `.ko.xz` first): size `2b0` (2 × 344-byte entries, no sentinel) is broken, and `408` (the same two plus the terminator, as in 7.3.3-310.t2) is intact.  `amdgpu-check.sh` runs this test on every kernel under `/lib/modules` and, as root, flags a broken one that is the GRUB default. No userspace step recovers a boot that hit it: the dead probe also wedges `wait_for_device_probe()`, so suspend and the final step of reboot hang too. Boot another kernel.
   What the overrun does depends on the build's layout. The callback (`imac5K_support_callback`) returns 0, so `dmi_check_system()` does not stop at the match: it walks past entry 2 into the next `.rodata` object, whose bytes are relocated pointers (`ip_discovery_ktype` in the fc44 build), and reads `matches[0].slot` from a pointer's low byte. The fc43 7.2.9 build oopsed every boot. The fc44 build (gcc 16, also `0x2b0`) booted cleanly on 2026-10-18 (no oops, `imac5K_support attached`, dm before smu), but that is luck, not a fix.
   The quirk also changes the panel. On 7.2.9 the 5K panel is driven as two 2560×2880 tiles, `eDP-1` + `DP-1` (`DP-1` reads `connected` with no external display; GNOME merges them into one 5120×2880 monitor), with `dpcd_set_link_settings … failed` / `enabling link 1 failed: 15` at boot. On 7.2.8 there is one `eDP-1`, 3840×2160 at most. On iMac20,2 the 7.2.9 tiled mode showed flickering vertical lines around the cursor and clicked elements, and the shutdown splash drew the whole image in each tile; booting 7.2.8 removed the flicker. The hardware cursor causes it: with `MUTTER_DEBUG_DISABLE_HW_CURSORS=1` (software cursor) the lines were gone on 7.3.3 (2026-11-13). 7.3.3-310.t2, with the table intact, drives the same two tiles with the same link errors (at boot and at resume) and shows the same cursor artifacts, so the overrun is not the cause.

5. **DM drop-in**: Installer creates a systemd drop-in so the display manager `After=`/`Wants=` the warmfix service.

## Fan daemon config path

`t2fanrd` has **`/etc/t2fand.conf`** (no "r") compiled in and **ignores `--config`**.
Verified: the daemon reported `low_temp: 55, high_temp: 75` matching `/etc/t2fand.conf`
byte for byte while `--config /etc/t2fanrd.conf` pointed at a file saying 60/90.
Installers before 2026-07 wrote `/etc/t2fanrd.conf`, which was never read — edits
there silently did nothing.

The section header must be `[Fan1]`, capital F — the daemon looks up `Fan{i}`.

`speed_curve = exponential` is **cubic**, over the CPU *package* temperature
(`coretemp` `temp1_input`, not per-core):

```
speed = min_speed + (max_speed - min_speed) * ((T - low_temp) / (high_temp - low_temp))^3
```

Measured on iMac20,2, 2026-07 (min 1200 / max 3600 RPM — the daemon has
logged `max_speed: 2700` on every cold-boot start since 2026-08; see below): the formula predicts 2673 RPM at
72 °C and the daemon wrote exactly 2673. With the old 55/75 band, **one** busy
thread reached 2673 RPM and **two** pinned the fan at 3600. At 8-16 threads the
package still sat at 93 °C mean / 100 °C peak *with the fan at 3600* — the chassis
cannot hold this CPU lower at any RPM, so ending the curve below ~90 °C only buys
noise. Hence the 60/90 default.

The daemon does smooth. `calc_speed()` itself is a pure function, but upstream
has fed it the mean of the last 50 temperature samples since November 2023, not
the instantaneous package temperature, which slews 47 → 86 °C in one second.
Measured 2026-10-17 with the bundled binary (the packaged build reacts faster; see Key file relationships):
- An 8 s, 8-thread burst took the package 41 → 81 °C. `fan1_output` stayed at
  1200 for ~4.5 s, then rose 1203 → 1581 while the temperature held at 80–81 °C,
  and was back at 1200 ~4 s after the load stopped.
- A 3 s burst to 76 °C left it at 1200. With no smoothing the curve gives ~1427 RPM.

Upstream also reads the GPU's `/sys/class/drm/card0/device/hwmon/hwmon*/temp1_input`
and uses the higher of the two, but globs both sensors once, at startup. At
~8 s amdgpu has not registered yet, and on probe-OK boots it gets DRM minor 1, not
0. So the GPU temperature never reaches the curve at boot. That is harmless at DPM
`low` (GPU ~40 °C), and mostly under `auto` too: 5 min of full GPU load reached
64 °C edge, just over the 60 °C curve start. A local T2FanRD build
(`/usr/local/bin/t2fanrd-dev`, drop-in `90-dev.conf`, outside this repo) globs
every card and rescans; with it the fan rose on GPU heat alone in that run.

`install.sh` **reconciles** an existing `/etc/t2fand.conf` rather than skipping it.
Skipping is what let a 55/75 band survive every re-install for months. Bands this
project has shipped (`55/75`, `55/85`, in `FAN_LEGACY_BANDS`) are backed up and
rewritten; a file the daemon cannot parse (`[fan1]` header, missing thresholds) is
rewritten because none of it was reaching the daemon anyway; anything else is
treated as hand-tuning and only warned about, overridable with `--force-fan-conf`.
Add any new shipped band to `FAN_LEGACY_BANDS` when changing the default, or the
old value becomes sticky again.

## Fan loud at idle — daemon dead, not curve wrong

This section, "Fan daemon config path" above and "Fan control across suspend"
below describe applesmc kernels (7.2 and older), where t2fanrd runs. For 7.3+
see "Fan on macsmc kernels" below.

Distinguish the two loud-fan modes by whether RPM tracks the CPU at all. If RPM
ramps while the package sits flat (measured: +551 RPM over 20 s at a constant
40 °C), the daemon is not running and the SMC firmware curve is driving the fan
off chassis/ambient sensors. A wrong curve, by contrast, still follows the CPU.

Check `fan1_manual` (want `1`) and `NRestarts` (want `0`), not just
`systemctl is-active` — `Restart=always` makes a hard-failing unit report
`activating (auto-restart)` forever, and each cycle's `ExecStopPost` rewrites
`fan1_manual=0`, so the restart loop actively re-hands the fan to the SMC every
`RestartSec`. This is why every `ExecStartPre=` modprobe in the fallback `t2fanrd.service`
carries a `-` prefix: the `apple_bce` → `t2bce_core` rename in the 7.1 t2 kernel
turned one of them into a hard failure and silently cost fan control. The real
start gate is the `t2-wait-sysfs.sh` precondition, not the modprobes.

Read curve limits from the daemon's own startup log (`journalctl -u t2fanrd`,
`min_speed`/`max_speed`), not from memory. On iMac20,2 with 7.2.x t2 kernels,
all 157 starts from 2026-08-25 to 2026-10-12 21:13 logged `max_speed: 2700`,
post-resume restarts included. From the `install.sh` run at 2026-10-12 21:14 on,
five starts logged 3600 instead — installer `try-restart`s and a
`t2fanrd-resume` restart — and `fan1_max` then reads 3600 with `fan1_manual=1`;
every cold-boot start still logs 2700 (the packaged build too: 7 of 7 cold boots on
2026-10-17, while its later restarts in a boot logged 3600). Cause unknown. So neither "always 2700"
nor "3600 once the daemon holds the fan" holds. The 3600 figures in the curve
section above were measured 2026-07.

The 2700 cap is the daemon's alone. It reads `fan1_min`/`fan1_max` once, at
startup, and clamps every write to them. With the daemon stopped,
`fan1_manual=1` and `fan1_output=3600`, the SMC spun the fan to 3575–3668 RPM
while `fan1_max` read 2700 (2026-10-17). Under all-core load the fan therefore
stops ~900 RPM short of what the SMC allows.

Fixed in T2FanRD, not here: branch `fan-limits-gpu-sensor` in `~/Dev/T2FanRD`
(not upstream) adds optional `min_speed`/`max_speed` keys to `[FanN]` in
`/etc/t2fand.conf`, overriding what sysfs reports. On iMac20,2 it runs as
`/usr/local/bin/t2fanrd-dev` through
`/etc/systemd/system/t2fanrd.service.d/90-dev.conf`, which overrides
`ExecStart=` from this repo's `10-` drop-in; neither file is installed or
removed by this repo. With `max_speed=3600` it logged 3600 on every start,
the 2026-10-17 cold boot included, and an all-core burst ran the fan at
3551–3667 RPM. The packaged build ignores the key. `install.sh`'s fan-config
verdict looks only at the band, `speed_curve` and `always_full_speed`, so it
keeps the extra line, but a rewrite (legacy band, `--force-fan-conf`) drops it.

## Fan control across suspend

`t2fanrd` asserts the SMC manual-control bit (`fan1_manual`) once at startup and
thereafter only writes `fan1_output`. The T2 SMC clears that bit across S3, so
after a resume the daemon's writes are ignored, the SMC drives the fan itself,
and it runs loud until the daemon is restarted. `t2fanrd-resume.service` handles
this: `WantedBy=` + `After=` the four sleep targets, which run *after* the
resume because `suspend.target` is itself `After=systemd-suspend.service`. It
uses `systemctl try-restart` so a deliberately stopped daemon is not resurrected.

`applesmc` sysfs lives at a deep, machine-specific path
(`/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:NN/APP0001:00/`). Use
`/sys/bus/acpi/devices/APP0001:*/` instead — flat and stable. A `*` glob spans
one path component only, so `/sys/devices/*/APP0001:*/` never matches.

## Fan on macsmc kernels (t2 7.3+)

The t2 kernels from 7.3 on bind the SMC (ACPI `APP0001`) with `macsmc_acpi`
(linux-t2-patches 3001–3014): `macsmc_core`, plus `macsmc_hwmon` (the fan, 83
temperatures and 45 powers on iMac20,2), `rtc_macsmc`, `macsmc_power` and
`macsmc_wdt`. The applesmc sections above do not apply there: no `fan1_manual`,
no `fan1_output`.

- **applesmc must not load.** On 7.3.3-310.t2 its probe failed with `-EIO`
  after 54 s, and its init with `driver init failed (ret=-5)` after 107 s, while
  it polled the ports macsmc drives. Its loader hung for as long, and
  `t2fanrd` (`After=applesmc-late`) started at 114 s, only to loop on the
  `fan1_manual` wait. `t2-applesmc.conf` blacklists the DMI autoload on every
  kernel. `applesmc-late` loads it explicitly, behind
  `ExecCondition=/bin/sh -c '! modinfo -n macsmc_acpi …'`. The check reads the
  running kernel's modules, not what is bound: macsmc_acpi may not have loaded
  yet when the unit starts.
- **The SMC's own curve drives the fan, and t2fanrd skips itself** (same
  check; the package drop-in needs `+`, because `ProtectKernelModules=` hides
  `/usr/lib/modules` from the sandbox). Measured 2026-11-13 on iMac20,2, 1 Hz:
  - Idle: target 1200 for 10 min, through 40 min of normal use, and for 10 min
    after a resume. The applesmc-era "loud at idle" and "loud after resume"
    did not happen; why the SMC behaves differently is unknown.
  - 8 busy threads: the target stayed at 1200 for 16 s (package ~91 °C), then
    went 1200 → 2700 in 47 s. Meanwhile the package hit 100 °C for 11 s and the
    SMC's CPU throttle key `PZ1T` read 20–97 W for 13 s. Then 2660–2740 RPM,
    package 93.9 °C mean, 4349 MHz, 130 W: the same 93/100 °C as t2fanrd at
    3600 RPM in 2026-07. Back to 1200 52 s after the load.
  - glmark2 terrain (45 W): the target stayed at 1200 for ~290 s (junction
    63–64 °C), then rose to ~2000 and peaked 14 s after the load ended. ~110 s
    later came an idle pulse to ~1900 for 35 s, with every logged temperature
    falling. A second run, logging all 128 SMC sensors, explains the shape:
    its one pulse (to 2171 for 59 s, from 8 s after the load ended) lasted
    exactly as long as an SMC power-zone event. For 29 s `PZ3T` ("Batt aux
    Throttle") read 100 and the zone targets `PZ2E` (dGPU) and `PZ3E` read 0,
    with no temperature crossing anything. It was the only such event in an
    hour of logging. The SMC's own power logic, not a sensor threshold.
  The SMC reads the GPU die (`TG0D`, equal to amdgpu's edge reading). The
  packaged t2fanrd globs `card0` only.
- **A daemon could not do much better.** `macsmc_hwmon` refuses a target
  outside [`fan1_min`, `fan1_max`] with `-EINVAL`, so 2700 is the ceiling.
  Writes need the unsafe `fan_control=1`, which taints the kernel; patch 9004
  only makes `fan1_target` 0644. The packaged t2fanrd (`0.1.2-2.20261113git4b5439a`,
  sharpenedblade branch `hwmon-support`) supports macsmc. It drives hwmon fans except
  `name=amdgpu` (amdgpu exposes a phantom `fan1_target`, max 4950), sets
  `fan_control=1` and writes `fan1_target`. On stop it writes nothing to a hwmon
  fan, so the fan stays manual at the last RPM. The driver re-asserts manual
  mode after a resume by itself. To run the daemon anyway, add a later drop-in
  with empty `ExecCondition=` and `ExecStartPre=` (the drop-in's wait is for
  applesmc's `fan1_manual`, which macsmc lacks). The binary must support macsmc:
  `t2fanrd-dev` from `90-dev.conf` does not.
- `rtc_macsmc` is `rtc0` (patch 3009 disables the other RTCs) and set the
  system clock ~21 min fast at boot; chrony stepped it back.

## Slow S3 resume — Apple's macOS `_PS0` methods

Every resume on iMac20,2 stalled 10.08–10.14 s in the noirq phase (102 resumes,
kernels 7.1.8–7.2.8, with and without GFXALT). `pm_print_times` plus an AML
method trace (`/sys/module/acpi/parameters/trace_state=enable`, layer `0x80`,
level `0x10` — the default level floods the 256 KB printk buffer) put 10.02 s of
it in four `_PS0` calls. Each one works only `If (OSDW ())`, and Linux answers
`_OSI("Darwin")` on Apple hardware, so `OSDW` is true:
- `RP05.UPSB._PS0` 5.39 s: two `CRMW` calls plus a 0.44 s link retrain that works.
- `NHI0._PS0` 2.47 s: one `CRMW`, via `CTBT`.
- `XHC2._PS0` 1.16 s: `PCED`'s 1 s DSB2 link wait plus 150 ms.
- `RP01._PS0` 1.01 s: the Wi-Fi link wait in `LNKW`. `_PS3` costs another 1.01 s on suspend.

`CRMW` reads through the UPSB PCIe2CIO mailbox (config `0x530`, the same layout
as `PCIE2CIO_CMD` in the kernel's `icm.c`), and the mailbox never answers: 15 of
15 `CIOR` timed out at 394 ms. Nothing was ever written. XHC2's wait never sees
DSB2's training bit clear, although `lspci` shows DSB2 `LLActRep-` and the link
up. `UGIO` took 0.4 ms, so the controller is already powered at resume. These
devices never runtime-suspend (`runtime_suspended_time` 0), so the methods run
only on system resume.

There is no knob to keep a PCI device in D0 across S3 (`pm_qos_no_power_off` is
not exposed for PCI). Hence `t2-tbt-acpi-patch.py`: it patches the *live*
firmware table at install time. `CRMW` becomes `Return (One)`. XHC2 `PCED`'s
second `Timer + 0x989680` becomes `+ 0`. The OEM revision goes from 0x1000 to
0x1001, because the table upgrade needs a higher one.

Once the override is active, `/sys/firmware/acpi/tables` shows the patched copy.
The patcher passes that copy through unchanged. `install.sh` re-emits it only
while `/sys/class/dmi/id/bios_version` matches `/var/lib/t2-pci-amdgpu/TbtOnPCH.bios`;
after a firmware update it leaves the table out so a boot shows the new one.

`--disable-wifi` installs `99-t2-wifi-off.rules`, which removes the `ARPT` parent
port at boot instead of patching RP01 in the DSDT. It also installs
`t2-wifi-off.conf` (blacklist `brcmfmac`): the driver otherwise probed before
the rule ran, and again after the warmfix's bus rescan re-added the port, with
a `__flush_work` WARN each time. The user of this repo does not use Wi-Fi, and
brcmfmac never bound the BCM4364 (no Apple firmware files).

The `pm_async=off` in `/proc/cmdline` comes from the t2 kernel's built-in
`CONFIG_CMDLINE`, not GRUB. The `Command line:` boot log line does not show it.

## Speaker audio — stereo sink over the 4-channel T2 output

On iMac20,2 the T2 card (`106b:1803`, ALSA driver `AppleT2x4`, card id `Audio`)
uses t2linux-audio's UCM `HiFi-x4.conf`. Its speaker sink has 4 channels,
`FL FR RL RR`, which are two driver pairs, not front and rear speakers.
t2linux-audio has DSP graphs only for MacBooks (`/usr/share/t2linux-audio/<NN_N>`),
none for `20_2`. Unfiltered, 5.1 puts FC dialogue on FL/FR and surround on RL/RR,
and stereo gets PipeWire's default `psd` upmix (RL/RR = L−R, delayed 12 ms). The
user heard voices "from the rear only" and "strange" sound in videos.

`install.sh` generates `/etc/wireplumber/wireplumber.conf.d/50-t2-stereo-speakers.conf`
from `t2-audio-wireplumber.conf.in` (`@T2_AUDIO_PCI@` → `pci-0000_04_00.3`,
`@MODEL@` → `iMac`), and only when `/proc/asound/cards` has an `AppleT2x4` card and
there is no DSP graph for the model. Match the driver with `/\]: AppleT2x4 - /`,
not `$3`: the padded `[Audio          ]` id splits into several fields. The file
holds a `node.software-dsp.rules` filter (builtin `copy` nodes: L → FL+RL, R →
FR+RR) and `monitor.alsa.rules` renames.

Design choices, each tried 2026-10-18:
- **The filter, not a `pipewire.conf.d` loopback.** WirePlumber creates the
  filter on the raw sink's `node-added` and frees it on removal, so a headphones
  profile leaves no dead "iMac Speakers" output behind.
- **No `node.dont-fallback` on a static loopback.** At PipeWire start the raw
  sink does not exist yet, so WirePlumber fails the stream ("defined target not
  found") and the loopback module unloads itself. The filter can use it, because
  it is created only after the target exists.
- **`hide-parent = false`.** Hiding removes the raw sink from every client, `pactl`
  and `wpctl` included. Its volume, a card route volume in `default-routes`, could
  then never be raised.
- **Priority does not pick the default output.** WirePlumber prefers its
  `default.configured.audio.sink.N` history, which on this machine lists the raw
  sink, over `priority.session`. The user has to pick "iMac Speakers" once.
- **The volume is restored by `media.name`.** `state-stream.lua` keys virtual
  `Audio/*` nodes as `Audio/Sink:media.name:<name>`, so renaming `media.name` loses
  the saved volume.

Expected warning, harmless: `wp-proxy: … wp_proxy_get_bound_id: runtime check failed`
each time the raw sink goes away — at login from gdm's greeter WirePlumber (the seat
moves to the user), at shutdown, and on a profile switch. WirePlumber 0.5.14's
`software-dsp.lua` (line 79) reads `node["bound-id"]` in its `node-removed` hook, after
the proxy is unbound; the filter is still freed. Any `node.software-dsp.rules` filter
triggers it, so the config cannot avoid it. Reproduced 2026-10-18 with
`pactl set-card-profile … off`, then back to `HiFi (Mic, Speaker)`.

Verify routing by recording `<raw>.monitor` with an explicit
`--channel-map=front-left,front-right,rear-left,rear-right` while playing L=440 Hz,
R=880 Hz. Muting the raw sink keeps the speakers silent, and the monitor still
carries the signal. Without the channel map the capture is remixed: the result
(FL=L, FR=0, RL=R, RR=L+R) looked like a broken graph when the graph was fine.

## Built-in microphone — +40 dB mono source over the raw T2 mic

The T2 exposes the mic raw: `amixer -c Audio` has no capture control (only
`Codec Output Jack`), and speech arrives near −50 dBFS. This holds for every
T2 Mac, not this unit: t2linux-audio's MacBook `mic.json` graphs all add gain
after their beamformer (mixer ×80, or 35 dB amp + 5 dB makeup), and there is
none for `20_2`. `install.sh` generates `/etc/wireplumber/wireplumber.conf.d/51-t2-mic.conf`
from `t2-mic-wireplumber.conf.in`, on the same gate as the speaker filter
(one `wp_conf` helper generates, installs or retires both). Its limiter is LV2
(`lv2-swh-plugins`, plus `pipewire-module-filter-chain-lv2`); there is no
check, because both are dependencies of t2linux-audio, whose UCM gives the raw
source the `HiFi__Mic__source` name the rule matches.

The graph, measured 2026-11-07 on iMac20,2:
- Raw channels: AUX0 and AUX1 correlate 0.93 in 200–4000 Hz, and AUX1 has a
  constant DC offset (~7e-3, −43 dBFS). AUX2 is a live capsule, uncorrelated
  with them (−0.2): it rose +14 dB with the others on a room transient. It is
  left out, since summing it without a beamformer would comb-filter.
- **Always capture with an AUX channel map.** `parecord --channels=3` without
  `--channel-map=aux0,aux1,aux2` remixes to FL/FR/FC and returns AUX2 as 100 %
  zeros. Handy's session concluded "AUX2 is dead" from exactly that.
- Builtin `mixer` gains and `linear`'s `Mult` are clamped to 10. `Mult = 100`
  silently gave +20.0 dB, so the gain is two stages: mixer 5+5 (+20 dB on the
  mean), then the limiter's `ingain = 20`. Measured at +40.0 dB against the raw
  source (+40.1 dB after the `linear` stage was folded into `ingain`).
- The limiter (`limit −1`, `release 0.25`) was checked by setting `limit −20` with
  `ingain +20`: peaks stopped at −20.00 dBFS.
- The same +40 dB in Handy's user-level filter gave dictation peaks near
  −5 dBFS and 22 dB above room noise. Handy's own `imac-t2` filter
  (`~/.config/pipewire/pipewire.conf.d/handy-mic-filter.conf`) duplicates this one;
  with both active there are two amplified sources, not double gain, but only
  one should stay.

The raw source keeps 100 % volume and stays visible (`hide-parent = false`),
as for the speakers. The filter's source has `priority.session = 2000` against
the raw source's 1728, but WirePlumber's saved default wins, so the user picks
"iMac Microphone" once.

## Unit ordering — no udev-settle

No unit may order itself after `systemd-udev-settle.service`. It is deprecated,
systemd logs a warning naming any unit that pulls it in, it cost 0.77 s of boot
on iMac20,2, and draining the coldplug queue never guaranteed the specific device
a unit needs. Wait on the precondition instead, via `t2-wait-sysfs.sh` as an
`ExecStartPre=`:

- `applesmc-late.service` → `/sys/bus/pci/drivers/t2bce_core/0000:*/consumer:t2bce_vhci:*` (bridge probe registered its VHCI child; the bare driver-dir link exists before probe runs)
- `t2fanrd.service` → `/sys/bus/acpi/devices/APP0001:*/fan1_manual` (the attribute it opens)
- `amdgpu-warmfix.service` → the generated script calls `t2-wait-sysfs.sh` on its own PCI node

`t2-wait-sysfs.sh` checks `-e` on the first expansion: `nullglob` only drops
words containing glob characters, so a literal path used to pass unexamined.

`applesmc` used to autoload from its DMI modalias during coldplug (on iMac20,2
it was up at t=7.10 s, before `applesmc-late.service` started, so that unit's
`modprobe` was a no-op). `t2-applesmc.conf` now blacklists that autoload, so on
kernels without macsmc the unit's `modprobe` is the path; on macsmc kernels the
unit skips itself (see "Fan on macsmc kernels").

## Key file relationships

- `install.sh` reads `amdgpu-reset-pci-template` and substitutes `ADDR` with the auto-detected GPU PCI slot (e.g., `03:00`) to generate `/usr/local/bin/amdgpu-pci-reset-load.sh`. The template is not a standalone script — it's a fragment that `install.sh` wraps with a header. Supports `--dry-run` to preview actions without changes.
- `uninstall.sh` reverses the installation: stops/disables services, removes all installed files, cleans up DM drop-in. Use `--all` to also remove `/boot/acpi_override.img` and `/etc/t2fand.conf` (plus the legacy `/etc/t2fanrd.conf`), `/etc/t2-pci-amdgpu.conf` and `/var/lib/t2-pci-amdgpu`. `--dry-run` previews; it still needs root to read GRUB state. It ends with only the outstanding cleanup steps, like the installer.
  `--all` keeps the image while anything still names it: `GRUB_EARLY_INITRD_LINUX_CUSTOM`, grubenv `early_initrd`, `grub.cfg`, or a BLS `initrd` line. Fedora's `blscfg` adds `early_initrd` files without checking they exist, and the x86 EFI `initrd` command then loads no initramfs at all, so the machine cannot mount root. Fedora's `10_linux` only *sets* `early_initrd` when the variable is non-empty and never clears it. Removing the variable and running `grub2-mkconfig` therefore leaves grubenv still naming the image. The cleanup needs `grub2-editenv - unset early_initrd`.
- `t2-grub-common.bash` holds the GRUB facts both scripts use: `grub_cfg` and `boot_mode`, `REQUIRED_PARAMS`, `grub_var`, grubenv, and `boot_entry_args`. `boot_entry_args` reads BLS entries via grubby, or their `options` lines when grubby is missing; on non-BLS it reads only grub.cfg's `10_linux` section, never os-prober's entries. The file is sourced, not run. It is `.bash`, not `.sh`, because `install.sh` copies every `*.sh` into `/usr/local/bin`. Its functions end in `return 0` where the last test could fail: both callers run under `set -e`.
- `install.sh` rebuilds `/boot/acpi_override.img` on every run, with fixed mtimes and `cpio --reproducible`. It replaces the image only when `cmp` finds a difference. It holds `GFXALT-multi.aml` and, when `t2-tbt-acpi-patch.py` accepts the live table, `TbtOnPCH.aml`. The patcher is run with `python3`, never installed.
- `t2-unit-state.sh` is the one copy of the unit list and the oneshot state logic; `amdgpu-check.sh` and `t2-gpu-status.sh` both call it from their own directory. A unit whose `ExecCondition=` said no (`Result=exec-condition`) shows as `skipped`. It tells `ran-once` from `not-run` via the boot's journal (`Finished`/`Failed to start`), not `ExecMainStartTimestamp`: systemd unloads an inactive unit nothing references (`t2fanrd-resume` after every resume), and an unloaded unit reports an empty timestamp.
- `amdgpu-check.sh` also reports GPU DPM level, clocks, temperatures and power; HDMI/DP audio (it flags the reset-boot gap by `.1`'s config BAR0 reading 0); the fan; and the tuned profile. The fan report depends on the running kernel. With `macsmc_acpi` it shows the SMC curve, `fan1_target` and range, a stray `applesmc` and a running t2fanrd (with `fan_control`). Otherwise it shows the daemon: binary path from `ExecStart`, `NRestarts`, `fan1_manual`, RPM, and the `max_speed` it logged at its last start. All of it works without root except the logged `max_speed` (journal access).
- `t2-applesmc.conf` → `/etc/modprobe.d/` on every install: `blacklist applesmc` (DMI autoload only; see "Fan on macsmc kernels"). Read at boot, so it is in the reboot list, but not an initramfs input: applesmc loads from the real root.
- `t2-sw-cursor.conf` → `/etc/environment.d/90-t2-sw-cursor.conf` on iMac20,1/iMac20,2 (DMI `product_name`), else retired: `MUTTER_DEBUG_DISABLE_HW_CURSORS=1`, against the tiled-5K cursor flicker (layer 4). Matched on the model, not the live tiling, so an install from a 7.2.8 boot still sets it. systemd's environment.d generator reads it at login (users and the gdm greeter), so `install.sh` prints a log-out hint instead of a reboot step.
- `amdgpu-navi10-imac.conf` → `/etc/modprobe.d/` only when `install.sh` finds a Navi 10 iMac20,x GPU at the detected slot; otherwise any copy is retired. It is an initramfs input, so changing it lists a dracut step. `amdgpu-check.sh` reports the mask in effect (`/sys/module/amdgpu/parameters/ppfeaturemask`) on those boards and warns if bit `0x2` is set.
- `t2-tuned-hda.conf.in` → `/etc/tuned/profiles/<name>/tuned.conf` for each stock tuned profile with an `[audio]` section (see layer 3). Applied live through tuned's D-Bus `reload` (`busctl call com.redhat.tuned /Tuned com.redhat.tuned.control reload`), not `tuned-adm profile <same>`, which would switch the selection mode to manual. A reload rolls back and re-applies the whole profile. Installed only when the GPU slot has a `.1` audio function; otherwise pristine copies are removed. A marked file counts as ours only while its settings (sections and keys, minus comments, blank lines and `summary=`) match the template's (`tuned_is_pristine`); an edited one is kept and judged like a user's file, by both scripts. Ours are replaced without a backup, and `uninstall.sh` removes pristine files and backups only. A change to the template's settings makes older generated files look edited, so it needs a migration.
- `t2-tuned.bash` (sourced by both scripts, not installed) holds the tuned facts: the marker, which is the template's first line and has no other copy; `tuned_is_ours`; `tuned_has_audio`; and `tuned_reload`, the D-Bus reload, which never fails because the callers run under `set -e`. `install.sh` reloads when it changed an override or when the live `power_save_controller` reads `Y`, then reads it again; `uninstall.sh` reloads after removing an override.
- `t2-tuned-audio.sh [PROFILE...]` prints `on|off|bad|none FILE`: what tuned does to `power_save_controller` under the profile (the active one by default), and the file that decides it. It runs tuned's public `Loader.load()`, with the `Locator`, `Factory` and `Merger` subclassed to record which file each profile came from and which file last set or dropped `reset_controller` per unit. Then it replays the audio plugin's device assignment. Each enabled `type=audio` unit is its own instance. Instances are sorted by priority (stable, file order breaks ties) and filtered by `cpuinfo_regex`/`uname_regex`. `snd_hda_intel` goes to the first one whose `devices=` match; `devices_udev_regex` matches nothing. So a second audio unit at the same priority gets no device, and one with a lower `priority=` takes it over. Values go through tuned's `get_bool`, then kstrtobool (`off` is false; a value neither accepts is `bad` and the write fails). Tested 2026-10-18 against scratch profiles for each case. A bash copy of tuned's resolver was tried first and dropped: it could not follow `${variables}` or audio units under other names, and it drifts with each tuned release.
- `t2-audio-wireplumber.conf.in` → `/etc/wireplumber/wireplumber.conf.d/50-t2-stereo-speakers.conf` (generated; see Speaker audio). `t2-mic-wireplumber.conf.in` → `51-t2-mic.conf` beside it (see Built-in microphone); it renames the raw mic, so the speaker file no longer does. WirePlumber reads it at session start, so it is not in the reboot list. `install.sh` prints a `systemctl --user restart wireplumber` hint instead when the file changed.
- `t2-amd-nodes.sh` is the one copy of "DRM nodes under an AMD VGA function", called the same way by both scripts. The warmfix template keeps its own per-slot `gpu_render_node`: the generated script must stand alone.
- `install.sh` ends with an "Action required" block listing only outstanding steps: `/etc/default/grub` edits, `grub2-mkconfig` when grubenv lacks `early_initrd=…acpi_override.img` (BLS) or `grub.cfg` lacks it, `grubby` when a BLS entry (`grubby --info=ALL`) lacks a required param, `dracut` for each `/boot/initramfs-<kver>.img` older than the newest dracut/modprobe input, and a reboot when a boot-time file's mtime is after `btime` or `/proc/cmdline`/the journal show the fix inactive. A finished install prints "No action required". A `--dry-run` counts every file it would install as changed now, so the preview lists the dracut and reboot steps the real run will need. Without root it skips the GRUB checks (grubenv, `/boot/loader/entries` and `grubby --info` are root-only) and says so instead of listing them. A deleted input (the `--disable-wifi` files) moves no mtime, so as root it is looked for inside each image with `lsinitrd -f`. The ACPI tables count as loaded only from their `ACPI: SSDT 0x…` header (GFXALT) or `Table Upgrade: override [SSDT-APPLE -TbtOnPCH]`, judged only when the boot's journal still starts at `Linux version`; the `table found in initrd` line names the file even when the load fails. This relies on `install_file` leaving identical files untouched: anything that rewrites unchanged files bumps mtimes and brings back spurious dracut/reboot steps.
- `install.sh` `try-restart`s `t2fanrd` at the end — the daemon reads its config and unit only at start, so a rewritten band otherwise changes nothing until reboot. Its "up to date" verdict compares `speed_curve` and `always_full_speed` too, not only the band.
- `install.sh` GRUB guidance: on Fedora 34+ the real config is `/boot/grub2/grub.cfg` even on EFI (`/boot/efi/EFI/fedora/grub.cfg` is a `configfile` stub — never overwrite it). With `GRUB_ENABLE_BLSCFG=true`, `grub2-mkconfig` does not touch `/boot/loader/entries/*.conf`, so cmdline params go in with `grubby --update-kernel=ALL --args=...` (which also updates `/etc/default/grub`). fc43's grub2-mkconfig has no `--update-bls-cmdline`; the installer uses it only if `--help` lists it.
- `GFXALT-multi.aml` is the precompiled ACPI table. Recompile from `.dsl` with: `iasl -ve -tc GFXALT-multi.dsl`
- `t2fanrd`: when the t2linux package is installed (`/usr/bin/t2fanrd` plus `/usr/lib/systemd/system/t2fanrd.service`), `install.sh` uses the package's build and sandboxed unit. It installs `t2fanrd-dropin.conf` as `t2fanrd.service.d/10-t2-pci-amdgpu.conf` and retires, with a backup, this repo's `/etc/systemd/system/t2fanrd.service` and `/usr/local/bin/t2fanrd`.
  The drop-in exists for these reasons:
  - It skips the daemon on macsmc kernels (`ExecCondition=+…`; see "Fan on macsmc kernels").
  - It names `ExecStart=/usr/bin/t2fanrd`, because a bare `t2fanrd` resolves `/usr/local/bin` first.
  - It adds the sysfs wait and `RestartSec=5`. The package unit has neither, so with the 100 ms default an early start would use up the start limit.
  - It runs the hand-back as `ExecStopPost=+…`, outside the sandbox.
  - It has no modprobes, because `ProtectKernelModules=true` blocks them and `applesmc-late` does them anyway.
  `enable_service` asks systemd for `LoadState` rather than requiring a file in `/etc`. Without the package, the bundled binary (a pre-April-2026 build that floods the journal with `ESC[1KSetting fan speed` lines) and the full unit are installed as before. Both builds glob `/sys/devices/pci*/*/*/*/APP0001:00/fan*`, which matches here through `firmware_node/subsystem/devices`.
  Measured 2026-10-17 after the switch:
  - The package build logs its parsed config at start, then nothing (0 bytes during a load burst).
  - It also reads `fan1_max` once. Its start after `install.sh` logged `max_speed: 3600`, but every cold-boot start logged 2700 (7 of 7 on 2026-10-17).
  - It responds faster: in an 8-thread burst at 85 °C it went 1200 → 2146 RPM in 6 s and to 2588 RPM by 10 s, where the bundled build reached 1581.
  - Stopping the unit still writes `fan1_manual=0`.
- `10-amdgpu-warmfix.conf` uses `force_drivers` (not `add_drivers`) to guarantee early module loading in initramfs. On T2 the early load buys no early KMS: amdgpu takes 3.3 s of CPU in `dracut-pre-udev` (blocking udev and the NVMe root disk), then defers its probe until `apple_gmux` binds in the real root (6.9–7.1 s). Do **not** add `apple_gmux` to move the probe into the initramfs. Tried 2026-10-13 on iMac20,2, 7 boots: the cold probe failed on 6 (about half before). The initramfs held switch-root until the failing probe ended (5.6 → 7.6 s), so gdm came no earlier. The re-probe took 4.3 s instead of 3.6 s, and Plymouth lost its splash. One boot failed the re-probe too, then the retry (`invalid ip discovery binary signature`) left the screen black. Consequence: any name that does not resolve to a real `.ko` is a **fatal** `dracut -f` error, not a warning. `pcieport` was listed here and broke `dracut -f` outright — the PCIe port driver is compiled into the PCI core (`CONFIG_PCIEPORTBUS=y`), so it is neither a module nor a `modules.builtin` entry. Check any addition with `modinfo -n <name>` before committing it.

## Testing and verification

No automated test suite — this is a system-level boot fix tested on real hardware. Verification after install + reboot:

```bash
# Check ACPI overrides loaded (journal, not dmesg: the printk buffer wraps)
journalctl -k -b | grep -E "Table Upgrade|GFXALT|TbtOnPCH"
# want: "Table Upgrade: install [SSDT-    LH-  GFXALT]", "Table Upgrade: override [SSDT-APPLE-TbtOnPCH]"

# Check resume speed: gap between these two lines was 10.1 s before the TbtOnPCH patch.
# Use the kernel's own timestamp (_SOURCE_MONOTONIC_TIMESTAMP). `-o short-monotonic`
# shows journald's receive time, and the resume lines all arrive in one burst
# (measured: 0.01 ms receive gap vs 0.677 s real).
journalctl -k -b -o json | jq -r 'select(.MESSAGE|test("Waking up from system sleep|EC: interrupt unblocked|PM: suspend exit")) | "\((._SOURCE_MONOTONIC_TIMESTAMP|tonumber)/1e6) \(.MESSAGE)"'

# Check warmfix ran successfully
sudo amdgpu-check.sh          # comprehensive health check
sudo t2-gpu-status.sh          # quick status snapshot
systemctl status amdgpu-warmfix.service
journalctl -u amdgpu-warmfix.service -b --no-pager
```

## Shell script conventions

- All scripts use `#!/usr/bin/env bash` with `set -Eeuo pipefail`, except `amdgpu-check.sh` — it is an interactive diagnostic and must report every failed probe rather than abort on the first one
- `install.sh` enables `DEBUG=1` tracing via `PS4` and `set -x`
- Colored output helpers: `say()` (cyan), `warn()` (yellow), `err()` (red)
- `install.sh` backs up existing files as `<file>.bak.YYYYMMDD-HHMMSS` before overwriting
- PCI slot addresses: strip domain prefix (`0000:`) to get slot root (e.g., `03:00`), but use full `0000:XX:XX.N` form in sysfs paths
