# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Stabilizes AMD GPU initialization on Apple T2 Intel Macs running Linux. The GPU fails to init reliably because Apple's ACPI tables lack power-resource methods the `amdgpu` driver expects, causing the PCI link to come up in an undefined state. The fix applies five ordered layers during boot: ACPI override → modprobe options → udev power pinning → PCI remove/rescan warmfix → display manager ordering.

Target hardware: iMac20,2 (i7-10700K + Navi10 / Radeon Pro 5700 XT). Should work on other T2 Macs with AMD GPUs.

## Architecture — boot sequence layers

The layers must execute in this order; each depends on the previous:

1. **ACPI SSDT** (`GFXALT-multi.dsl` → `.aml`): Injects `_PR3`/`_DSM` stubs into GPU device across four possible ACPI paths (`PEG0/EGP0/EGP1`, `PEG0/PEGP`, `RP05.PEGP`, `RP21.PEGP`). Packed into `/boot/acpi_override.img` as an early initrd cpio. Uses `CondRefOf` to match the right path at boot.

2. **modprobe.d** (`amdgpu.conf`): Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level, blacklists `radeon`, and sets `snd_hda_intel.power_save_controller=0`. Duplicates GRUB cmdline params intentionally — survives rescue boots that bypass GRUB.

3. **udev rules**:
   - `99-amdgpu-t2.rules`: Pins `power/control=on` for AMD VGA (class `0x030000`) and HDMI audio (class `0x040300`) at device bind, before the driver claims the device. Also pins DPM to `low` after the driver loads for thermal stability.
     The audio write is best-effort: `snd_hda_intel` calls `pm_runtime_allow()` from async probe work and resets the attribute to `auto` after udev has run, so no udev rule can win that race. `power_save_controller=0` is what actually keeps that function awake — `azx_runtime_idle()` then returns `-EBUSY`, so `power/control` still reads `auto` but nothing acts on it. Verify with `runtime_status`, not `control`.
   - `99-t2-usb.rules`: Pins `power/control=on` for USB root hubs (`idVendor=0x1d6b`, hub class `0x09`). T2 xHCI hubs autosuspend aggressively and silently stop reporting device-attach events on suspended ports — symptom is plugged devices missing from `lsusb` with no kernel log entry.

4. **Warmfix service** (`amdgpu-warmfix.service` → runs generated `amdgpu-pci-reset-load.sh`): Oneshot before display-manager. Waits for amdgpu's coldplug probe of the VGA function to settle; if the GPU's *own* render node (`<pci dev>/drm/renderD*`) then exists the cold probe succeeded and the reset is skipped. Never test the global `/dev/dri/renderD*`: i915 on an iGPU-enabled MacBookPro or an eGPU publishes there too and would mask a dead dGPU. Otherwise removes GPU PCI functions (.1 audio first, then .0 VGA), rescans bus, waits up to 20s for that render node. Retries once on failure. Skips if `nomodeset` or `amdgpu.modeset=0` is on cmdline. `Environment=AMDGPU_WARMFIX_ALWAYS_RESET=1` in a drop-in forces the reset every boot; only the exact value `1` does (`0`/`false` leave the skip on).
   Never write `remove` while `amdgpu_pci_probe()` is in flight: the write blocks on the device lock, then lands on the failing probe's cleanup path and oopses in `vcn_v2_0_sw_fini` on VCN state the unwind already freed — on iMac20,2, a boot wedged at the splash on 3 of 4 boots. The `driver` symlink cannot gate this, because `driver_sysfs_add()` creates it *before* the probe runs. Settled means DRM nodes under the PCI device (probe succeeded), or no `driver` symlink *and* amdgpu's module is `live` *and* the device is not on the deferred-probe list (failed and unbound). No symlink alone is not enough: a probe that has not started looks identical. On T2 the cold probe is normally *deferred* — amdgpu returns `-EPROBE_DEFER` via `vga_switcheroo_client_probe_defer()` until `apple_gmux` binds, then re-runs from `deferred_probe_work_func` — and with no udev-settle nothing orders the warmfix after gmux. The deferred list is `/sys/kernel/debug/devices_deferred`; without debugfs the script falls back to "ACPI `APP000B` present and `apple_gmux` not live". DRM nodes are not a hard end-of-probe signal either (`drm_dev_register()` precedes xcp/kfd/fbdev setup, which can still fail under the lock), so the settled state must hold for 4 polls (~1.5s) before a `remove`.
   A probe that never settles aborts the unit (exit 1) instead of removing anyway. On 7.2.9-310.t2 the probe worker oopses every boot and dies holding the device lock; the old "proceeding anyway" `remove` then sat in D state forever, unkillable, holding the display manager ~7 min. The wait shortens to 15s once `/proc/sys/kernel/tainted` has bit 128 (oops).
   That kernel's cause: a new iMac20,x DMI quirk, `imac5k_table`, which registers the display IP block before SMU and lacks its `{}` terminator. Check any kernel's module with `nm -S amdgpu.ko | grep imac5k_table` (decompress the `.ko.xz` first): size `2b0` (2 × 344-byte entries, no sentinel) is broken. No userspace step recovers a boot that hit it: the dead probe also wedges `wait_for_device_probe()`, so suspend and the final step of reboot hang too. Boot another kernel.

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
reported `max_speed: 2700` on every start since 2026-08; see below): the formula predicts 2673 RPM at
72 °C and the daemon wrote exactly 2673. With the old 55/75 band, **one** busy
thread reached 2673 RPM and **two** pinned the fan at 3600. At 8-16 threads the
package still sat at 93 °C mean / 100 °C peak *with the fan at 3600* — the chassis
cannot hold this CPU lower at any RPM, so ending the curve below ~90 °C only buys
noise. Hence the 60/90 default.

There is no smoothing, averaging or hysteresis — `calc_speed()` is a pure function
of the instantaneous package temperature, which slews 47 → 86 °C in one second.

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
`min_speed`/`max_speed`), not from memory. On iMac20,2 with 7.2.x t2 kernels all
149 starts logged since 2026-08-25 report `max_speed: 2700`, and `fan1_max`
reads 2700 *with* `fan1_manual=1` — so an earlier note here claiming it reads
3600 once the daemon holds the fan was wrong. The 3600 figures in the curve
section above were measured 2026-07 and have not been seen since.

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
- `uninstall.sh` reverses the installation: stops/disables services, removes all installed files, cleans up DM drop-in. Use `--all` to also remove `/boot/acpi_override.img` and `/etc/t2fand.conf` (plus the legacy `/etc/t2fanrd.conf`).
- `t2-unit-state.sh` is the one copy of the unit list and the oneshot state logic; `amdgpu-check.sh` and `t2-gpu-status.sh` both call it from their own directory. It tells `ran-once` from `not-run` via the boot's journal (`Finished`/`Failed to start`), not `ExecMainStartTimestamp`: systemd unloads an inactive unit nothing references (`t2fanrd-resume` after every resume), and an unloaded unit reports an empty timestamp.
- `install.sh` `try-restart`s `t2fanrd` at the end — the daemon reads its config and unit only at start, so a rewritten band otherwise changes nothing until reboot. Its "up to date" verdict compares `speed_curve` and `always_full_speed` too, not only the band.
- `install.sh` GRUB guidance: on Fedora 34+ the real config is `/boot/grub2/grub.cfg` even on EFI (`/boot/efi/EFI/fedora/grub.cfg` is a `configfile` stub — never overwrite it). With `GRUB_ENABLE_BLSCFG=true`, `grub2-mkconfig` does not touch `/boot/loader/entries/*.conf`, so cmdline params go in with `grubby --update-kernel=ALL --args=...` (which also updates `/etc/default/grub`). fc43's grub2-mkconfig has no `--update-bls-cmdline`; the installer uses it only if `--help` lists it.
- `GFXALT-multi.aml` is the precompiled ACPI table. Recompile from `.dsl` with: `iasl -ve -tc GFXALT-multi.dsl`
- `t2fanrd` is a prebuilt binary from [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD), not built from source in this repo.
- `10-amdgpu-warmfix.conf` uses `force_drivers` (not `add_drivers`) to guarantee early module loading in initramfs. Consequence: any name that does not resolve to a real `.ko` is a **fatal** `dracut -f` error, not a warning. `pcieport` was listed here and broke `dracut -f` outright — the PCIe port driver is compiled into the PCI core (`CONFIG_PCIEPORTBUS=y`), so it is neither a module nor a `modules.builtin` entry. Check any addition with `modinfo -n <name>` before committing it.

## Testing and verification

No automated test suite — this is a system-level boot fix tested on real hardware. Verification after install + reboot:

```bash
# Check ACPI override loaded
dmesg | grep -i "ACPI: Early table override"

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
