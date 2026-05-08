# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Stabilizes AMD GPU initialization on Apple T2 Intel Macs running Linux. The GPU fails to init reliably because Apple's ACPI tables lack power-resource methods the `amdgpu` driver expects, causing the PCI link to come up in an undefined state. The fix applies five ordered layers during boot: ACPI override → modprobe options → udev power pinning → PCI remove/rescan warmfix → display manager ordering.

Target hardware: iMac20,2 (i7-10700K + Navi10 / Radeon Pro 5700 XT). Should work on other T2 Macs with AMD GPUs.

## Architecture — boot sequence layers

The layers must execute in this order; each depends on the previous:

1. **ACPI SSDT** (`GFXALT-multi.dsl` → `.aml`): Injects `_PR3`/`_DSM` stubs into GPU device across four possible ACPI paths (`PEG0/EGP0/EGP1`, `PEG0/PEGP`, `RP05.PEGP`, `RP21.PEGP`). Packed into `/boot/acpi_override.img` as an early initrd cpio. Uses `CondRefOf` to match the right path at boot.

2. **modprobe.d** (`amdgpu.conf`): Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level, blacklists `radeon`. Duplicates GRUB cmdline params intentionally — survives rescue boots that bypass GRUB.

3. **udev rules**:
   - `99-amdgpu-t2.rules`: Pins `power/control=on` for AMD VGA (class `0x030000`) and HDMI audio (class `0x040300`) at device bind, before the driver claims the device. Also pins DPM to `low` after the driver loads for thermal stability.
   - `99-t2-usb.rules`: Pins `power/control=on` for USB root hubs (`idVendor=0x1d6b`, hub class `0x09`). T2 xHCI hubs autosuspend aggressively and silently stop reporting device-attach events on suspended ports — symptom is plugged devices missing from `lsusb` with no kernel log entry.

4. **Warmfix service** (`amdgpu-warmfix.service` → runs generated `amdgpu-pci-reset-load.sh`): Oneshot before display-manager. Removes GPU PCI functions (.1 audio first, then .0 VGA), rescans bus, waits up to 20s for `/dev/dri/renderD*`. Retries once on failure. Skips if `nomodeset` or `amdgpu.modeset=0` is on cmdline.

5. **DM drop-in**: Installer creates a systemd drop-in so the display manager `After=`/`Wants=` the warmfix service.

## Key file relationships

- `install.sh` reads `amdgpu-reset-pci-template` and substitutes `ADDR` with the auto-detected GPU PCI slot (e.g., `03:00`) to generate `/usr/local/bin/amdgpu-pci-reset-load.sh`. The template is not a standalone script — it's a fragment that `install.sh` wraps with a header. Supports `--dry-run` to preview actions without changes.
- `uninstall.sh` reverses the installation: stops/disables services, removes all installed files, cleans up DM drop-in. Use `--all` to also remove `/boot/acpi_override.img` and `/etc/t2fanrd.conf`.
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

- All scripts use `#!/usr/bin/env bash` with `set -Eeuo pipefail`
- `install.sh` enables `DEBUG=1` tracing via `PS4` and `set -x`
- Colored output helpers: `say()` (cyan), `warn()` (yellow), `err()` (red)
- `install.sh` backs up existing files as `<file>.bak.YYYYMMDD-HHMMSS` before overwriting
- PCI slot addresses: strip domain prefix (`0000:`) to get slot root (e.g., `03:00`), but use full `0000:XX:XX.N` form in sysfs paths
