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

4. **Warmfix service** (`amdgpu-warmfix.service` → runs generated `amdgpu-pci-reset-load.sh`): Oneshot before display-manager. Removes GPU PCI functions (.1 audio first, then .0 VGA), rescans bus, waits up to 20s for `/dev/dri/renderD*`. Retries once on failure. Skips if `nomodeset` or `amdgpu.modeset=0` is on cmdline.

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

Measured on iMac20,2 (min 1200 / max 3600 RPM): the formula predicts 2673 RPM at
72 °C and the daemon wrote exactly 2673. With the old 55/75 band, **one** busy
thread reached 2673 RPM and **two** pinned the fan at 3600. At 8-16 threads the
package still sat at 93 °C mean / 100 °C peak *with the fan at 3600* — the chassis
cannot hold this CPU lower at any RPM, so ending the curve below ~90 °C only buys
noise. Hence the 60/90 default.

There is no smoothing, averaging or hysteresis — `calc_speed()` is a pure function
of the instantaneous package temperature, which slews 47 → 86 °C in one second.

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

- `applesmc-late.service` → `/sys/bus/pci/drivers/apple-bce/0000:*` (bridge bound)
- `t2fanrd.service` → `/sys/bus/acpi/devices/APP0001:*/fan1_manual` (the attribute it opens)
- `amdgpu-warmfix.service` → the generated script waits for its own PCI node

Note `applesmc` autoloads from its DMI modalias during coldplug — on iMac20,2 it
is already up at t=7.10 s, before `applesmc-late.service` even starts, so that
unit's `modprobe` is normally a no-op. It is kept as insurance, not as the path.

## Key file relationships

- `install.sh` reads `amdgpu-reset-pci-template` and substitutes `ADDR` with the auto-detected GPU PCI slot (e.g., `03:00`) to generate `/usr/local/bin/amdgpu-pci-reset-load.sh`. The template is not a standalone script — it's a fragment that `install.sh` wraps with a header. Supports `--dry-run` to preview actions without changes.
- `uninstall.sh` reverses the installation: stops/disables services, removes all installed files, cleans up DM drop-in. Use `--all` to also remove `/boot/acpi_override.img` and `/etc/t2fand.conf` (plus the legacy `/etc/t2fanrd.conf`).
- `GFXALT-multi.aml` is the precompiled ACPI table. Recompile from `.dsl` with: `iasl -ve -tc GFXALT-multi.dsl`
- `t2fanrd` is a prebuilt binary from [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD), not built from source in this repo.
- `10-amdgpu-warmfix.conf` uses `force_drivers` (not `add_drivers`) to guarantee early module loading in initramfs.

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
