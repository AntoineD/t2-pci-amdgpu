# AMDGPU Warmfix for Mac Intel (T2)

Stabilizes AMD GPU initialization on Apple T2 iMac running Linux.
Developed and tested on **iMac20,2** (i7-10700K + Navi10 / Radeon Pro 5700 XT).
Should also work on other Mac Intel T2 models with AMD GPUs.

**Tested on:** Fedora 43, Ubuntu

---

## How it works

The fix operates in five layers, from earliest to latest in the boot sequence:

| Layer | What | When | Why |
|---|---|---|---|
| **ACPI override** | Injects `_PR3`/`_DSM` stubs into the GPU ACPI device | Early initrd (before kernel) | Apple's ACPI tables omit the power-resource and device-specific methods the Linux AMDGPU driver expects; without them the PCI link comes up in an undefined state and the driver fails to initialize |
| **modprobe.d** | Sets `amdgpu.aspm=0`, `amdgpu.runpm=0`, blacklists `radeon` | Module load | Persists ASPM-off and disables runtime power management so the GPU cannot be powered down after the driver claims it; blacklisting `radeon` prevents it from racing `amdgpu` |
| **udev rule** | Pins GPU PCI functions to `power/control=on` | Device bind (before driver) | PCIe runtime PM can suspend the GPU between the ACPI fix and the driver binding; pinning the power state to `on` closes that window |
| **Warmfix service** | PCI remove → rescan with retry + readiness check | systemd, before display manager | Forcing the PCI bus to re-enumerate the GPU slot makes the kernel re-read its BARs and re-run PCI init cleanly; the retry handles the ~15 s corruption case where the first init attempt fails |
| **DM drop-in** | Ensures display manager starts only after warmfix | systemd ordering | Without explicit ordering, GDM can race the warmfix and start against an uninitialised GPU, producing a black screen or failed compositor |

---

## File overview

### Installer

| File | Description |
|---|---|
| `install.sh` | Main installer — runs all steps below |
| `amdgpu-reset-pci-template` | Template for the PCI reset script; `ADDR` is replaced with the detected slot at install time |

### Systemd units

| File | Installed to | Description |
|---|---|---|
| `amdgpu-warmfix.service` | `/etc/systemd/system/` | Runs the PCI reset at boot, before the display manager. Skips itself if `nomodeset` or `amdgpu.modeset=0` is set. |
| `t2fanrd.service` | `/etc/systemd/system/` | Runs the T2 fan daemon |
| `applesmc-late.service` | `/etc/systemd/system/` | Loads `applesmc` after `apple_bce` is ready |

### Scripts and binaries

| File | Installed to | Description |
|---|---|---|
| `amdgpu-check.sh` | `/usr/local/bin/` | GPU health check: render node, module state, PCI power state, warmfix log. Offers live warmfix re-trigger if GPU is missing (requires root). |
| `t2-gpu-status.sh` | `/usr/local/bin/` | Quick GPU and service status snapshot |
| `t2fanrd` | `/usr/local/bin/` | Prebuilt T2 fan controller daemon — [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD) |

### Config files

| File | Installed to | Description |
|---|---|---|
| `amdgpu.conf` | `/etc/modprobe.d/` | Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level; blacklists `radeon` |
| `99-amdgpu-t2.rules` | `/etc/udev/rules.d/` | Pins AMD VGA and HDMI audio PCI functions to `power/control=on` at device bind |
| `10-amdgpu-warmfix.conf` | `/etc/dracut.conf.d/` | Embeds `amdgpu`, `nvme`, `thunderbolt`, `pcieport` in initramfs |
| `20-amdgpu-t2-cmdline.conf` | `/etc/dracut.conf.d/` | Embeds kernel params as initramfs fallback (used only when bootloader passes no cmdline) |

### ACPI

| File | Description |
|---|---|
| `GFXALT-multi.aml` | Compiled ACPI SSDT — packed into `/boot/acpi_override.img` by the installer |
| `GFXALT-multi.dsl` | Source for the above. To recompile: `iasl -ve -tc GFXALT-multi.dsl` |

---

## Install

```bash
sudo ./install.sh
```

The installer will:

1. Build `/boot/acpi_override.img` from `GFXALT-multi.aml`
2. Install all `*.service` units to `/etc/systemd/system/`
3. Auto-detect the AMD GPU PCI slot and generate `/usr/local/bin/amdgpu-pci-reset-load.sh`
4. Install scripts and the `t2fanrd` binary to `/usr/local/bin/`
5. Install `modprobe.d`, `udev`, and `dracut` config files
6. Create a default `/etc/t2fanrd.conf` if none exists
7. Enable `amdgpu-warmfix`, `t2fanrd`, and `applesmc-late` services
8. Create a display manager drop-in so the DM starts after warmfix

Existing files are backed up as `<file>.bak.YYYYMMDD-HHMMSS` before replacement.

> **Note:** The T2Linux patched kernel (providing `apple_bce`, `applesmc`) must already be installed.

---

## GRUB configuration (required)

Edit `/etc/default/grub` and add or adjust:

```
GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.img"
GRUB_CMDLINE_LINUX="pci=noaer pcie_aspm=off amdgpu.aspm=0 amdgpu.runpm=0"
```

Remove `nomodeset` from `GRUB_CMDLINE_LINUX` if present — it disables `amdgpu`.

Then regenerate grub config:

```bash
# Legacy boot (iMac T2)
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# EFI systems
sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
```

The installer prints the correct command for your detected boot mode at the end of installation.

---

## Verification after reboot

**1. ACPI override loaded:**
```bash
dmesg | grep -i "ACPI: Early table override"
```

**2. Kernel cmdline:**
```bash
cat /proc/cmdline | grep acpi_override.img
```

**3. Full GPU health check:**
```bash
sudo amdgpu-check.sh
```

Or manually:
```bash
systemctl status amdgpu-warmfix.service --no-pager
journalctl -u amdgpu-warmfix.service -b --no-pager
```

Expected warmfix log lines (success path):
```
[amdgpu-warmfix] Stage 2: PCI remove/rescan (attempt 1)
[amdgpu-warmfix] remove 0000:03:00.1 (audio)
[amdgpu-warmfix] remove 0000:03:00.0 (vga)
[amdgpu-warmfix] rescanning PCI bus
[amdgpu-warmfix] GPU ready after Xs: /dev/dri/renderD128
[amdgpu-warmfix] Stage 2: GPU initialized successfully
```

If the first attempt fails, the warmfix retries automatically:
```
[amdgpu-warmfix] Stage 2: GPU not ready after first attempt — retrying
[amdgpu-warmfix] Stage 2: GPU initialized on retry
```

---

## Troubleshooting

**Booted with `nomodeset`:**
System falls back to framebuffer (no acceleration). `amdgpu-warmfix` detects this and exits immediately.

**Black screen (without `nomodeset`):**
Check that `/boot/acpi_override.img` exists, confirm GRUB params are set, regenerate `grub.cfg`.

**GPU not detected after boot:**
Run `sudo amdgpu-check.sh` — it will report the state of each layer and offer to restart the warmfix service live.

**Wrong PCI slot targeted:**
The GPU is usually at a fixed slot (e.g. `0000:03:00.0` VGA, `0000:03:00.1` audio).
Verify with `lspci -nn | grep VGA`. If the slot is wrong, edit `/usr/local/bin/amdgpu-pci-reset-load.sh` manually.

**Fans spinning at full speed:**
`apple_bce` or T2 kernel patches not active. Check that `t2fanrd.service` is enabled and running, and that the T2Linux patched kernel is installed.

**Warmfix didn't run:**
```bash
systemctl status amdgpu-warmfix.service
# verify the drop-in exists:
ls /etc/systemd/system/gdm.service.d/10-amdgpu-warmfix.conf
```

---

## Known issues

- On first-attempt GPU init failure, the screen may show a horizontal corruption artifact for ~15–20 seconds. The warmfix retries automatically and the driver loads correctly.
- After such an event, rebooting into macOS may trigger 1–2 crash reports (`remoted` watchdog) and one automatic reboot within the first 5 minutes. macOS then runs normally.
- Maximum resolution is 4K — 5K is not supported by `amdgpu`.

---

## Notes

- Developed on Fedora 43, iMac20,2 (legacy BIOS boot).
- Should work on other T2 Macs with AMD GPUs — feedback welcome.
- `t2fanrd` binary: SHA256 `32612f571e8de56497c7c36dc32b4f6ba85cd25888afd5bb25c6de735f5fe52f` — verify against [GnomedDev/T2FanRD releases](https://github.com/GnomedDev/T2FanRD/releases) before running.
