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
   Neither `amdgpu.aspm=0` nor `pcie_aspm=off` turns ASPM off on the GPU link. `amdgpu.aspm=0` only skips amdgpu's own ASPM setup, and `pcie_aspm=off` leaves firmware's configuration alone. Apple's firmware enables L1: `lspci -vv` shows `ASPM L1 Enabled` on 00:01.0, 01:00.0, 02:00.0 and 03:00.0. It also enables L1 on NVMe, T2 and Ethernet; only the Thunderbolt chain has it off. Turning it off for real does not cure the cold-probe failure. Tested 2026-10-17 with `pcie_aspm.policy=performance`, which works here because the kernel skips `_OSC` on Apple and assumes PCIe control (`OS assumes control of [...]`). lspci confirmed `ASPM Disabled` on every GPU link, and the cold probe still failed with `SMU: No response msg_reg: 6`. Dropping `pcie_aspm=off` saves no power either: with `CONFIG_PCIEASPM_DEFAULT=y` the kernel keeps firmware's settings.

3. **udev rules**:
   - `99-amdgpu-t2.rules`: Pins `power/control=on` for AMD VGA (class `0x030000`) and HDMI audio (class `0x040300`) at device bind, before the driver claims the device. Also pins DPM to `low` after the driver loads for thermal stability, and records amdgpu's `bind` uevent as `AMDGPU_WARMFIX_BOUND=1`, the warmfix's signal that the probe returned success.
     The audio write is best-effort: `snd_hda_intel` calls `pm_runtime_allow()` from async probe work and resets the attribute to `auto` after udev has run, so no udev rule can win that race. `power_save_controller=0` is what actually keeps that function awake — `azx_runtime_idle()` then returns `-EBUSY`, so `power/control` still reads `auto` but nothing acts on it. Verify with `runtime_status`, not `control`.
   - `99-t2-usb.rules`: Pins `power/control=on` for USB root hubs (`idVendor=0x1d6b`, hub class `0x09`). T2 xHCI hubs autosuspend aggressively and silently stop reporting device-attach events on suspended ports — symptom is plugged devices missing from `lsusb` with no kernel log entry.

4. **Warmfix service** (`amdgpu-warmfix.service` → runs generated `amdgpu-pci-reset-load.sh`): Oneshot before display-manager. Waits for amdgpu's coldplug probe of the VGA function to settle; if the GPU's *own* render node (`<pci dev>/drm/renderD*`) then exists the cold probe succeeded and the reset is skipped. Never test the global `/dev/dri/renderD*`: i915 on an iGPU-enabled MacBookPro or an eGPU publishes there too and would mask a dead dGPU. Otherwise removes GPU PCI functions (.1 audio first, then .0 VGA), rescans bus, waits up to 20s for that render node. Retries once on failure. Skips if `nomodeset` or `amdgpu.modeset=0` is on cmdline. `Environment=AMDGPU_WARMFIX_ALWAYS_RESET=1` in a drop-in forces the reset every boot; only the exact value `1` does (`0`/`false` leave the skip on).
   Never write `remove` while `amdgpu_pci_probe()` is in flight: the write blocks on the device lock, then lands on the failing probe's cleanup path and oopses in `vcn_v2_0_sw_fini` on VCN state the unwind already freed — on iMac20,2, a boot wedged at the splash on 3 of 4 boots. The `driver` symlink cannot gate this, because `driver_sysfs_add()` creates it *before* the probe runs. Settled means DRM nodes under the PCI device (probe succeeded), or no `driver` symlink *and* amdgpu's module is `live` *and* the device is not on the deferred-probe list (failed and unbound). No symlink alone is not enough: a probe that has not started looks identical. On T2 the cold probe is normally *deferred* — amdgpu returns `-EPROBE_DEFER` via `vga_switcheroo_client_probe_defer()` until `apple_gmux` binds, then re-runs from `deferred_probe_work_func` — and with no udev-settle nothing orders the warmfix after gmux. The deferred list is `/sys/kernel/debug/devices_deferred`; without debugfs the script falls back to "ACPI `APP000B` present and no driver bound to its PNP node" (`APP000B:*/physical_node/driver`). Not `/sys/module/apple_gmux/initstate`: a built-in gmux has no such file, which read as deferred forever and cost a 60 s wait plus a failed unit. DRM nodes are not a hard end-of-probe signal either (`drm_dev_register()` precedes xcp/kfd/fbdev setup, which can still fail under the lock), so the settled state must hold for 1.5 s before a `remove`. The wait's deadlines run on `/proc/uptime` (read without a fork), not on a poll count: 600 polls with their forks drifted past the nominal 60 s. That wait cost 1.5–2.0 s on every boot, so end signals from outside sysfs shorten it. *Bound*: udev processed the `bind` uevent, which `driver_bound()` sends only after the probe returned 0; `99-amdgpu-t2.rules` records it as `AMDGPU_WARMFIX_BOUND=1` and clears it on `unbind` (udev keeps recorded properties across later events, so a stale record would pass a rebind's running probe for a finished one), and the wait ends at once. Never use udev's `DRIVER=` for this: `really_probe()` sets `dev->driver` before the probe runs, so any uevent during the probe carries it. *Fbdev*: the kernel logged `[drm] fbN: … frame buffer device` for this function, which also ends the wait at once. `amdgpu_pci_probe()` sets up fbdev after every step that can fail it; only debugfs (a failure is logged, not returned) and runtime PM (off, `runpm=0`) follow before `return 0`. It beats the bind record by ~0.86 s at boot (fbdev line at 8.475 s, bind seen at 9.337 s: udev is busy with amdgpu's child devices), and it survives switch-root, which the bind record does not. No fbdev device appears in sysfs on this kernel (only `fbcon`), so the kernel log is the only place to see it. *Failed*: the kernel logged `probe with driver amdgpu failed`. Both kernel-log signals count only when they are the last probe event logged for the function: every probe past the vga_switcheroo deferral logs `initializing kernel modesetting` first, so an earlier probe's lines (before a rescan or a rebind) are superseded. The window before a new probe logs its start is covered by also requiring the settled state. A failure still needs ~0.5 s of settled state: the line comes before `driver_sysfs_remove()` and the devres teardown, which run under the device lock (amdgpu's `ttm finalized` landed 25 ms after the line). The warmfix logs which signal ended the wait; `(no end signal seen)` means it fell back to the full ~1.5 s.
   After a reset the warmfix also restores the HDMI/DP audio function (`restore_gpu_audio`). Every re-probe finds PSP still running from the earlier probe, so `nv_need_reset_on_init()` asks for a PSP mode1 reset. That reset wipes the whole ASIC, `.1` included, and amdgpu restores config space for `.0` only. `.1`'s BAR0 then reads 0 while the kernel still has it assigned, `snd_hda_intel` fails (`CORB reset timeout … CORBRP = 65535`, "GPU sound probed, but not operational"), and there is no HDMI/DP audio. This happened on all 12 reset boots in a 25-boot sample. When config space reads 0 against an assigned `resource`, the warmfix waits for `snd_hda_intel`'s probe to end, removes `.1`, and rescans only `/sys/class/pci_bus/0000:<bus>/rescan`. The bus still holds `.0`, so that is a plain rescan, and the Wi-Fi port is not re-added. Verified live 2026-10-17. The step never fails the unit.
   A probe that never settles aborts the unit (exit 1) instead of removing anyway. On 7.2.9-310.t2 the probe worker oopses every boot and dies holding the device lock; the old "proceeding anyway" `remove` then sat in D state forever, unkillable, holding the display manager ~7 min. The wait shortens to 15s once `/proc/sys/kernel/tainted` has bit 128 (oops).
   That kernel's cause: a new iMac20,x DMI quirk, `imac5k_table`, which registers the display IP block before SMU and lacks its `{}` terminator. Check any kernel's module with `nm -S amdgpu.ko | grep imac5k_table` (decompress the `.ko.xz` first): size `2b0` (2 × 344-byte entries, no sentinel) is broken.  `amdgpu-check.sh` runs this test on every kernel under `/lib/modules` and, as root, flags a broken one that is the GRUB default. No userspace step recovers a boot that hit it: the dead probe also wedges `wait_for_device_probe()`, so suspend and the final step of reboot hang too. Boot another kernel.

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
Measured 2026-10-17 with the bundled binary:
- An 8 s, 8-thread burst took the package 41 → 81 °C. `fan1_output` stayed at
  1200 for ~4.5 s, then rose 1203 → 1581 while the temperature held at 80–81 °C,
  and was back at 1200 ~4 s after the load stopped.
- A 3 s burst to 76 °C left it at 1200. With no smoothing the curve gives ~1427 RPM.

Upstream also reads the GPU's `/sys/class/drm/card0/device/hwmon/hwmon*/temp1_input`
and uses the higher of the two, but globs both sensors once, at startup. At
~8 s amdgpu has not registered yet, and on probe-OK boots it gets DRM minor 1, not
0. So the GPU temperature never reaches the curve at boot. That is harmless while
DPM is pinned `low` (GPU ~40 °C).

`install.sh` **reconciles** an existing `/etc/t2fand.conf` rather than skipping it.
Skipping is what let a 55/75 band survive every re-install for months. Bands this
project has shipped (`55/75`, `55/85`, in `FAN_LEGACY_BANDS`) are backed up and
rewritten; a file the daemon cannot parse (`[fan1]` header, missing thresholds) is
rewritten because none of it was reaching the daemon anyway; anything else is
treated as hand-tuning and only warned about, overridable with `--force-fan-conf`.
Add any new shipped band to `FAN_LEGACY_BANDS` when changing the default, or the
old value becomes sticky again.

## Fan loud at idle — daemon dead, not curve wrong

Distinguish the two loud-fan modes by whether RPM tracks the CPU at all. If RPM
ramps while the package sits flat (measured: +551 RPM over 20 s at a constant
40 °C), the daemon is not running and the SMC firmware curve is driving the fan
off chassis/ambient sensors. A wrong curve, by contrast, still follows the CPU.

Check `fan1_manual` (want `1`) and `NRestarts` (want `0`), not just
`systemctl is-active` — `Restart=always` makes a hard-failing unit report
`activating (auto-restart)` forever, and each cycle's `ExecStopPost` rewrites
`fan1_manual=0`, so the restart loop actively re-hands the fan to the SMC every
`RestartSec`. This is why every `ExecStartPre=` modprobe in `t2fanrd.service`
carries a `-` prefix: the `apple_bce` → `t2bce_core` rename in the 7.1 t2 kernel
turned one of them into a hard failure and silently cost fan control. The real
start gate is the `t2-wait-sysfs.sh` precondition, not the modprobes.

Read curve limits from the daemon's own startup log (`journalctl -u t2fanrd`,
`min_speed`/`max_speed`), not from memory. On iMac20,2 with 7.2.x t2 kernels,
all 157 starts from 2026-08-25 to 2026-10-12 21:13 logged `max_speed: 2700`,
post-resume restarts included. From the `install.sh` run at 2026-10-12 21:14 on,
five starts logged 3600 instead — installer `try-restart`s and a
`t2fanrd-resume` restart — and `fan1_max` then reads 3600 with `fan1_manual=1`;
every cold-boot start still logs 2700. Cause unknown. So neither "always 2700"
nor "3600 once the daemon holds the fan" holds. The 3600 figures in the curve
section above were measured 2026-07.

The 2700 cap is the daemon's alone. It reads `fan1_min`/`fan1_max` once, at
startup, and clamps every write to them. With the daemon stopped,
`fan1_manual=1` and `fan1_output=3600`, the SMC spun the fan to 3575–3668 RPM
while `fan1_max` read 2700 (2026-10-17). Under all-core load the fan therefore
stops ~900 RPM short of what the SMC allows. A fix belongs in T2FanRD.

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

Note `applesmc` autoloads from its DMI modalias during coldplug — on iMac20,2 it
is already up at t=7.10 s, before `applesmc-late.service` even starts, so that
unit's `modprobe` is normally a no-op. It is kept as insurance, not as the path.

## Key file relationships

- `install.sh` reads `amdgpu-reset-pci-template` and substitutes `ADDR` with the auto-detected GPU PCI slot (e.g., `03:00`) to generate `/usr/local/bin/amdgpu-pci-reset-load.sh`. The template is not a standalone script — it's a fragment that `install.sh` wraps with a header. Supports `--dry-run` to preview actions without changes.
- `uninstall.sh` reverses the installation: stops/disables services, removes all installed files, cleans up DM drop-in. Use `--all` to also remove `/boot/acpi_override.img` and `/etc/t2fand.conf` (plus the legacy `/etc/t2fanrd.conf`) and `/var/lib/t2-pci-amdgpu`. `--dry-run` previews; it still needs root to read GRUB state. It ends with only the outstanding cleanup steps, like the installer.
  `--all` keeps the image while anything still names it: `GRUB_EARLY_INITRD_LINUX_CUSTOM`, grubenv `early_initrd`, `grub.cfg`, or a BLS `initrd` line. Fedora's `blscfg` adds `early_initrd` files without checking they exist, and the x86 EFI `initrd` command then loads no initramfs at all, so the machine cannot mount root. Fedora's `10_linux` only *sets* `early_initrd` when the variable is non-empty and never clears it. Removing the variable and running `grub2-mkconfig` therefore leaves grubenv still naming the image. The cleanup needs `grub2-editenv - unset early_initrd`.
- `t2-grub-common.bash` holds the GRUB facts both scripts use: `grub_cfg` and `boot_mode`, `REQUIRED_PARAMS`, `grub_var`, grubenv, and `boot_entry_args`. `boot_entry_args` reads BLS entries via grubby, or their `options` lines when grubby is missing; on non-BLS it reads only grub.cfg's `10_linux` section, never os-prober's entries. The file is sourced, not run. It is `.bash`, not `.sh`, because `install.sh` copies every `*.sh` into `/usr/local/bin`. Its functions end in `return 0` where the last test could fail: both callers run under `set -e`.
- `install.sh` rebuilds `/boot/acpi_override.img` on every run, with fixed mtimes and `cpio --reproducible`. It replaces the image only when `cmp` finds a difference. It holds `GFXALT-multi.aml` and, when `t2-tbt-acpi-patch.py` accepts the live table, `TbtOnPCH.aml`. The patcher is run with `python3`, never installed.
- `t2-unit-state.sh` is the one copy of the unit list and the oneshot state logic; `amdgpu-check.sh` and `t2-gpu-status.sh` both call it from their own directory. It tells `ran-once` from `not-run` via the boot's journal (`Finished`/`Failed to start`), not `ExecMainStartTimestamp`: systemd unloads an inactive unit nothing references (`t2fanrd-resume` after every resume), and an unloaded unit reports an empty timestamp.
- `t2-amd-nodes.sh` is the one copy of "DRM nodes under an AMD VGA function", called the same way by both scripts. The warmfix template keeps its own per-slot `gpu_render_node`: the generated script must stand alone.
- `install.sh` ends with an "Action required" block listing only outstanding steps: `/etc/default/grub` edits, `grub2-mkconfig` when grubenv lacks `early_initrd=…acpi_override.img` (BLS) or `grub.cfg` lacks it, `grubby` when a BLS entry (`grubby --info=ALL`) lacks a required param, `dracut` for each `/boot/initramfs-<kver>.img` older than the newest dracut/modprobe input, and a reboot when a boot-time file's mtime is after `btime` or `/proc/cmdline`/the journal show the fix inactive. A finished install prints "No action required". A `--dry-run` counts every file it would install as changed now, so the preview lists the dracut and reboot steps the real run will need. Without root it skips the GRUB checks (grubenv, `/boot/loader/entries` and `grubby --info` are root-only) and says so instead of listing them. A deleted input (the `--disable-wifi` files) moves no mtime, so as root it is looked for inside each image with `lsinitrd -f`. The ACPI tables count as loaded only from their `ACPI: SSDT 0x…` header (GFXALT) or `Table Upgrade: override [SSDT-APPLE -TbtOnPCH]`, judged only when the boot's journal still starts at `Linux version`; the `table found in initrd` line names the file even when the load fails. This relies on `install_file` leaving identical files untouched: anything that rewrites unchanged files bumps mtimes and brings back spurious dracut/reboot steps.
- `install.sh` `try-restart`s `t2fanrd` at the end — the daemon reads its config and unit only at start, so a rewritten band otherwise changes nothing until reboot. Its "up to date" verdict compares `speed_curve` and `always_full_speed` too, not only the band.
- `install.sh` GRUB guidance: on Fedora 34+ the real config is `/boot/grub2/grub.cfg` even on EFI (`/boot/efi/EFI/fedora/grub.cfg` is a `configfile` stub — never overwrite it). With `GRUB_ENABLE_BLSCFG=true`, `grub2-mkconfig` does not touch `/boot/loader/entries/*.conf`, so cmdline params go in with `grubby --update-kernel=ALL --args=...` (which also updates `/etc/default/grub`). fc43's grub2-mkconfig has no `--update-bls-cmdline`; the installer uses it only if `--help` lists it.
- `GFXALT-multi.aml` is the precompiled ACPI table. Recompile from `.dsl` with: `iasl -ve -tc GFXALT-multi.dsl`
- `t2fanrd` is a prebuilt binary from [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD), not built from source in this repo.
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
