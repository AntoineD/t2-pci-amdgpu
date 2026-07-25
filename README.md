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
| **modprobe.d** | Sets `amdgpu.aspm=0`, `amdgpu.runpm=0`, `snd_hda_intel.power_save_controller=0`, blacklists `radeon` | Module load | Persists ASPM-off and disables runtime power management so neither GPU function can be powered down after its driver claims it; blacklisting `radeon` prevents it from racing `amdgpu` |
| **udev rule** | Pins GPU PCI functions to `power/control=on`; sets DPM to `low` | Device bind / driver load | PCIe runtime PM can suspend the GPU between the ACPI fix and the driver binding; pinning the power state to `on` closes that window. DPM `low` prevents thermal crashes on T2 hardware. |
| **Warmfix service** | PCI remove → rescan with retry + readiness check | systemd, before display manager | Forcing the PCI bus to re-enumerate the GPU slot makes the kernel re-read its BARs and re-run PCI init cleanly; the retry handles the ~15 s corruption case where the first init attempt fails |
| **DM drop-in** | Ensures display manager starts only after warmfix | systemd ordering | Without explicit ordering, GDM can race the warmfix and start against an uninitialised GPU, producing a black screen or failed compositor |

---

## File overview

### Installer

| File | Description |
|---|---|
| `install.sh` | Main installer — runs all steps below |
| `uninstall.sh` | Removes all installed files, disables services. Use `--all` to also remove `/boot/acpi_override.img` and `/etc/t2fand.conf`. |
| `amdgpu-reset-pci-template` | Template for the PCI reset script; `ADDR` is replaced with the detected slot at install time |

### Systemd units

| File | Installed to | Description |
|---|---|---|
| `amdgpu-warmfix.service` | `/etc/systemd/system/` | Runs the PCI reset at boot, before the display manager. Skips itself if `nomodeset` or `amdgpu.modeset=0` is set. |
| `t2fanrd.service` | `/etc/systemd/system/` | Runs the T2 fan daemon |
| `t2fanrd-resume.service` | `/etc/systemd/system/` | Restarts `t2fanrd` after resume — the SMC drops manual fan control across S3, so without this the fan runs loud until the daemon is restarted by hand |
| `applesmc-late.service` | `/etc/systemd/system/` | Loads `applesmc` once the `apple-bce` PCI driver has bound |

None of these units order themselves after `systemd-udev-settle.service`. It is
deprecated — systemd logs `systemd-udev-settle.service is deprecated. Please fix
<unit> not to pull it in` and names the offenders — it cost 0.77 s of boot on
iMac20,2, and draining the coldplug queue never actually guaranteed that the
device a given unit needs is present. Each unit now waits on its own precondition:
`apple-bce` binding, the `fan1_manual` attribute, or the GPU's PCI node.

### Scripts and binaries

| File | Installed to | Description |
|---|---|---|
| `amdgpu-check.sh` | `/usr/local/bin/` | GPU health check: render node, module state, PCI power state, warmfix log. Offers live warmfix re-trigger if GPU is missing (requires root). |
| `t2-gpu-status.sh` | `/usr/local/bin/` | Quick GPU and service status snapshot |
| `t2-wait-sysfs.sh` | `/usr/local/bin/` | Blocks until a sysfs path matching any given glob appears. Used as `ExecStartPre=` in place of `udevadm settle` — waits for the one device the unit needs instead of the whole coldplug queue |
| `t2fanrd` | `/usr/local/bin/` | Prebuilt T2 fan controller daemon — [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD) |

### Config files

| File | Installed to | Description |
|---|---|---|
| `amdgpu.conf` | `/etc/modprobe.d/` | Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level; blacklists `radeon`; sets `snd_hda_intel.power_save_controller=0` so the GPU's HDMI audio function stays out of runtime suspend |
| `99-amdgpu-t2.rules` | `/etc/udev/rules.d/` | Pins the AMD VGA function to `power/control=on` at device bind; sets DPM to `low`. Also targets the HDMI audio function, but that write is best-effort — `snd_hda_intel` resets it to `auto` when it binds, which is why the module option above exists |
| `99-t2-usb.rules` | `/etc/udev/rules.d/` | Pins USB root hubs (`idVendor=1d6b`, hub class `09`) to `power/control=on`. T2 xHCI hubs autosuspend aggressively and stop reporting device attach events; pinning the root hubs awake fixes USB-to-Ethernet adapters and similar devices not appearing in `lsusb`. |
| `10-amdgpu-warmfix.conf` | `/etc/dracut.conf.d/` | Embeds `amdgpu`, `nvme` and `thunderbolt` in the initramfs via `force_drivers`. Every name must resolve to a real module — `force_drivers` makes a missing one a fatal `dracut -f` error |
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
6. Create a default `/etc/t2fand.conf` if none exists
7. Enable `amdgpu-warmfix`, `t2fanrd`, `t2fanrd-resume`, and `applesmc-late` services
8. Create a display manager drop-in so the DM starts after warmfix

Existing files are backed up as `<file>.bak.YYYYMMDD-HHMMSS` before replacement.

> **Note:** The T2Linux patched kernel (providing `apple_bce`, `applesmc`) must already be installed.

---

## GRUB configuration (required)

`install.sh` reads your current `/etc/default/grub` and prints the exact lines to
write, with your existing parameters preserved — follow that output rather than
copying the generic form below.

Two variables need to be right:

**`GRUB_EARLY_INITRD_LINUX_CUSTOM`** must include `acpi_override.img`. If the
variable is absent, add it:

```
GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.img"
```

**`GRUB_CMDLINE_LINUX`** must contain all four parameters below. **Add them to
whatever is already on that line — do not replace it**, or you will drop distro
defaults such as `rhgb quiet`:

```
pci=noaer  pcie_aspm=off  amdgpu.aspm=0  amdgpu.runpm=0
```

So a line that starts as

```
GRUB_CMDLINE_LINUX="rhgb quiet pcie_aspm=off amdgpu.aspm=0"
```

becomes

```
GRUB_CMDLINE_LINUX="rhgb quiet pcie_aspm=off amdgpu.aspm=0 pci=noaer amdgpu.runpm=0"
```

Also remove `nomodeset` and `amdgpu.modeset=0` from that line if present — either
one disables `amdgpu` entirely.

Then regenerate GRUB config and initramfs:

```bash
# Legacy boot (iMac T2)
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# EFI systems
sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg

# Rebuild initramfs (required for dracut config changes to take effect)
sudo dracut -f
```

The installer prints the correct commands for your detected boot mode at the end of installation.

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

**Fan config edits have no effect:**
`t2fanrd` reads **`/etc/t2fand.conf`** — no "r" — compiled in, and ignores
`--config`. If you edited `/etc/t2fanrd.conf`, nothing happened. The section
header must also be `[Fan1]`, capital F.

```bash
sudo nano /etc/t2fand.conf
sudo systemctl restart t2fanrd
journalctl -u t2fanrd -n 30 --no-pager | grep -E 'low_temp|high_temp|speed_curve'
```

The daemon prints the config it actually parsed at startup — that grep is the
only reliable confirmation an edit took.

**Fan too loud under light CPU load:**
`speed_curve = exponential` is cubic over the CPU *package* temperature:
`speed = min + (max-min)·((T-low)/(high-low))³`. With a narrow band the fan
saturates almost immediately — on iMac20,2 with `low=55 high=75`, one busy
thread gave 2673 RPM and two gave the full 3600. Widen the band; `low_temp=60`,
`high_temp=90` is the shipped default. At full load the package sits at 90-100 °C
*regardless* of RPM, so a curve ending below ~90 °C costs noise and buys nothing.

**Fans loud after waking from sleep:**
The SMC clears the manual fan-control bit (`fan1_manual`) across S3. `t2fanrd`
sets that bit only at startup, so after resume it keeps writing `fan1_output`
to a fan the SMC has taken back — the fan ramps up and stays there.
`t2fanrd-resume.service` restarts the daemon on resume to re-assert manual mode.

```bash
systemctl is-enabled t2fanrd-resume.service     # expect: enabled
journalctl -u t2fanrd-resume.service -b         # one entry per resume
cat /sys/bus/acpi/devices/APP0001:*/fan1_manual # expect: 1 while t2fanrd runs
```

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
