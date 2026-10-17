# AMDGPU Warmfix for Mac Intel (T2)

Stabilizes AMD GPU initialization on Apple T2 iMac running Linux.
Developed and tested on **iMac20,2** (i7-10700K + Navi10 / Radeon Pro 5700 XT).
Should also work on other Mac Intel T2 models with AMD GPUs.

**Tested on:** Fedora 43

---

## How it works

The fix operates in five layers, from earliest to latest in the boot sequence:

| Layer | What | When | Why |
| --- | --- | --- | --- |
| **ACPI override** | Injects `_PR3`/`_DSM` stubs into the GPU ACPI device | Early initrd (before kernel) | Apple's ACPI tables omit the power-resource and device-specific methods the Linux AMDGPU driver expects; without them the PCI link comes up in an undefined state and the driver fails to initialize |
| **modprobe.d** | Sets `amdgpu.aspm=0`, `amdgpu.runpm=0`, `snd_hda_intel.power_save_controller=0`, blacklists `radeon` | Module load | Keeps amdgpu from setting up ASPM itself and disables runtime power management, so neither GPU function can be powered down after its driver claims it; blacklisting `radeon` prevents it from racing `amdgpu`. Neither this nor `pcie_aspm=off` turns off the ASPM L1 that Apple's firmware enables on the GPU link |
| **udev rule** | Pins GPU PCI functions to `power/control=on`; sets DPM to `low` | Device bind / driver load | PCIe runtime PM can suspend the GPU between the ACPI fix and the driver binding; pinning the power state to `on` closes that window. DPM `low` prevents thermal crashes on T2 hardware. |
| **Warmfix service** | PCI remove → rescan with retry + readiness check; skipped when amdgpu's cold probe already succeeded | systemd, before display manager | Forcing the PCI bus to re-enumerate the GPU slot makes the kernel re-read its BARs and re-run PCI init cleanly; the retry handles the ~15 s corruption case where the first init attempt fails |
| **DM drop-in** | Ensures display manager starts only after warmfix | systemd ordering | Without explicit ordering, GDM can race the warmfix and start against an uninitialised GPU, producing a black screen or failed compositor |

The same ACPI override image also carries a patched copy of Apple's Thunderbolt
table, which takes ~9 s off every resume from suspend — see
[Slow resume from suspend](#slow-resume-from-suspend).

---

## File overview

### Installer

| File | Description |
| --- | --- |
| `install.sh` | Main installer — runs all steps below |
| `uninstall.sh` | Removes all installed files, disables services, then prints the GRUB and initramfs cleanup steps this system still needs. `--all` also removes `/boot/acpi_override.img` and `/etc/t2fand.conf`, but keeps the image while GRUB still loads it: GRUB loads no initramfs at all when one of its files is missing, and the system would not boot. `--dry-run` previews everything. |
| `t2-grub-common.bash` | GRUB helpers sourced by both scripts (not installed) |
| `amdgpu-reset-pci-template` | Template for the PCI reset script; `ADDR` is replaced with the detected slot at install time |

### Systemd units

| File | Installed to | Description |
| --- | --- | --- |
| `amdgpu-warmfix.service` | `/etc/systemd/system/` | Runs the PCI reset at boot, before the display manager, if amdgpu's cold probe failed. Skips itself if `nomodeset` or `amdgpu.modeset=0` is set. |
| `t2fanrd-dropin.conf` | `/etc/systemd/system/t2fanrd.service.d/10-t2-pci-amdgpu.conf` | When the t2linux `t2fanrd` package is installed (`/usr/bin/t2fanrd`): adds to the package's own unit the wait for the fan attribute, `RestartSec=5`, ordering after `applesmc-late`, and handing the fan back to the SMC on stop. The package's sandboxed unit and newer build are used as they are. |
| `t2fanrd.service` | `/etc/systemd/system/` | Fallback without the package: runs the bundled T2 fan daemon |
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
| --- | --- | --- |
| `amdgpu-check.sh` | `/usr/local/bin/` | GPU health check: render node, module state, installed kernels with the broken `imac5k_table` quirk, PCI power state, warmfix log. Offers live warmfix re-trigger if GPU is missing (requires root). |
| `t2-gpu-status.sh` | `/usr/local/bin/` | Quick GPU and service status snapshot |
| `t2-wait-sysfs.sh` | `/usr/local/bin/` | Blocks until a sysfs path matching any given glob appears. Used as `ExecStartPre=` in place of `udevadm settle` — waits for the one device the unit needs instead of the whole coldplug queue |
| `t2fanrd` | `/usr/local/bin/` | Fallback without the package: prebuilt T2 fan controller daemon — [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD). With the package installed, the installer removes any copy here (backed up) |

### Config files

| File | Installed to | Description |
| --- | --- | --- |
| `amdgpu.conf` | `/etc/modprobe.d/` | Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level; blacklists `radeon`; sets `snd_hda_intel.power_save_controller=0` so the GPU's HDMI audio function stays out of runtime suspend |
| `99-amdgpu-t2.rules` | `/etc/udev/rules.d/` | Pins the AMD VGA function to `power/control=on` at device bind; sets DPM to `low`; records amdgpu's successful bind (`AMDGPU_WARMFIX_BOUND=1`) so the warmfix can stop waiting for the probe. Also targets the HDMI audio function, but that write is best-effort — `snd_hda_intel` resets it to `auto` when it binds, which is why the module option above exists |
| `99-t2-usb.rules` | `/etc/udev/rules.d/` | Pins USB root hubs (`idVendor=1d6b`, hub class `09`) to `power/control=on`. T2 xHCI hubs autosuspend aggressively and stop reporting device attach events; pinning the root hubs awake fixes USB-to-Ethernet adapters and similar devices not appearing in `lsusb`. |
| `99-t2-wifi-off.rules` | `/etc/udev/rules.d/` | Only with `install.sh --disable-wifi`. Removes the Wi-Fi (ACPI `ARPT`) and its root port from the PCI tree at boot, so Apple's 1 s link waits on that port no longer run on every suspend and resume. Bluetooth is unaffected — it is on the UART. |
| `t2-wifi-off.conf` | `/etc/modprobe.d/` | Only with `install.sh --disable-wifi`. Blacklists `brcmfmac`, which without Apple's firmware files only fails its probe and logs a `__flush_work` warning every boot. |
| `10-amdgpu-warmfix.conf` | `/etc/dracut.conf.d/` | Embeds `amdgpu`, `nvme` and `thunderbolt` in the initramfs via `force_drivers`. Every name must resolve to a real module — `force_drivers` makes a missing one a fatal `dracut -f` error |
| `20-amdgpu-t2-cmdline.conf` | `/etc/dracut.conf.d/` | Embeds kernel params as initramfs fallback (used only when bootloader passes no cmdline) |

### ACPI

| File | Description |
| --- | --- |
| `GFXALT-multi.aml` | Compiled ACPI SSDT — packed into `/boot/acpi_override.img` by the installer |
| `GFXALT-multi.dsl` | Source for the above. To recompile: `iasl -ve -tc GFXALT-multi.dsl` |
| `t2-tbt-acpi-patch.py` | Run by the installer: reads Apple's `TbtOnPCH` SSDT from `/sys/firmware/acpi/tables`, patches two methods, and the result goes into the same image. No Apple code is shipped in this repo. |

---

## Install

```bash
sudo ./install.sh                     # install
sudo ./install.sh --dry-run           # preview, change nothing
sudo ./install.sh --force-fan-conf    # also reset a hand-tuned /etc/t2fand.conf
sudo ./install.sh --disable-wifi      # also drop the unused Wi-Fi (faster suspend/resume)
```

The installer will:

1. Build `/boot/acpi_override.img` from `GFXALT-multi.aml` and a patched copy of
   Apple's `TbtOnPCH` table (rebuilt every run, replaced only if it changed)
2. Install all `*.service` units to `/etc/systemd/system/`
3. Auto-detect the AMD GPU PCI slot and generate `/usr/local/bin/amdgpu-pci-reset-load.sh`
4. Install scripts to `/usr/local/bin/`, plus the bundled `t2fanrd` binary when the t2linux `t2fanrd` package is not installed
5. Install `modprobe.d`, `udev`, and `dracut` config files
6. Create `/etc/t2fand.conf`, or reconcile an existing one (see below)
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
# Fedora 34+, EFI or legacy: /boot/grub2/grub.cfg is the real config.  On EFI,
# /boot/efi/EFI/fedora/grub.cfg is a stub that hands off to it — do not
# overwrite it with grub2-mkconfig.
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Rebuild initramfs (required for dracut config changes to take effect)
sudo dracut -f
```

With BLS (`GRUB_ENABLE_BLSCFG=true`, Fedora's default) each kernel's command line
lives in its own `/boot/loader/entries/*.conf`, and `grub2-mkconfig` does not
rewrite them — editing `GRUB_CMDLINE_LINUX` alone never reaches the kernel.
Apply the parameters with grubby, which also updates `/etc/default/grub`:

```bash
sudo grubby --update-kernel=ALL --args="pci=noaer pcie_aspm=off amdgpu.aspm=0 amdgpu.runpm=0"
sudo grubby --update-kernel=ALL --remove-args="nomodeset amdgpu.modeset=0"
```

The installer prints the right commands for your system at the end of installation.

---

## Verification after reboot

**1. ACPI override loaded:**

```bash
journalctl -k -b | grep -E "Table Upgrade|GFXALT|TbtOnPCH"
# want: ACPI: Table Upgrade: install [SSDT-    LH-  GFXALT]
#       ACPI: Table Upgrade: override [SSDT-APPLE-TbtOnPCH]
#       ACPI: SSDT ... (v02 APPLE  TbtOnPCH 00001001 INTL 20160930)
```

Use the journal rather than `dmesg`: the kernel's 256 KB log buffer wraps, and
after a few hours of uptime these early-boot lines are gone from it.

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

When amdgpu's cold probe succeeded, no reset is needed:

```
[amdgpu-warmfix] amdgpu probe ended (fbdev), settled after X.Xs
[amdgpu-warmfix] cold probe already succeeded: /dev/dri/renderD128 — skipping remove/rescan
```

When the cold probe failed, the warmfix resets the GPU:

```
[amdgpu-warmfix] amdgpu probe ended (failed), settled after X.Xs
[amdgpu-warmfix] Stage 2: PCI remove/rescan (attempt 1)
[amdgpu-warmfix] remove /sys/bus/pci/devices/0000:03:00.1 (audio)
[amdgpu-warmfix] remove /sys/bus/pci/devices/0000:03:00.0 (vga)
[amdgpu-warmfix] rescanning PCI bus
[amdgpu-warmfix] GPU ready X.Xs after rescan: /dev/dri/renderD128
[amdgpu-warmfix] Stage 2: GPU initialized successfully
```

The first line says what ended the wait for amdgpu's probe: `fbdev` (the
kernel logged amdgpu's framebuffer), `bound` (udev saw the driver bind) or
`failed` (the kernel logged the probe failure). `settled after X.Xs (no end
signal seen)` means none showed up and the warmfix waited the full ~1.5 s
instead.

If the first attempt fails, the warmfix retries automatically:

```
[amdgpu-warmfix] Stage 2: GPU not ready after first attempt — retrying
[amdgpu-warmfix] Stage 2: GPU initialized on retry
```

To force the reset on every boot, even after a successful cold probe:

```bash
sudo systemctl edit amdgpu-warmfix.service
# add:
[Service]
Environment=AMDGPU_WARMFIX_ALWAYS_RESET=1
```

Only the value `1` enables it; to turn it off, set `0` or remove the drop-in.

The warmfix checks the render node *under the AMD GPU's own PCI device*, not
`/dev/dri/renderD*` — an iGPU (i915) or eGPU render node does not count as the
AMD GPU having come up.

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

**Fan loud and unrelated to CPU load** (ramps at idle, ignores a cool package):
`t2fanrd` is not running, so the SMC is driving the fan on its own firmware
curve — which follows chassis/ambient sensors, not the CPU package.

```bash
systemctl is-active t2fanrd.service                        # want: active
systemctl show t2fanrd.service -p NRestarts --value        # want: 0
cat /sys/bus/acpi/devices/APP0001:*/fan1_manual            # want: 1
```

`fan1_manual = 0` means the SMC owns the fan. A nonzero `NRestarts` that keeps
climbing means the unit is in a restart loop: each failed start runs
`ExecStopPost`, which hands the fan back to the SMC every `RestartSec`. Check
why it fails with `journalctl -u t2fanrd -b`. The usual cause is an
`ExecStartPre=` module load that no longer resolves — the T2 bridge was renamed
`apple_bce` → `t2bce_core` in the 7.1 t2 kernel, and a stale unit file still
naming `apple_bce` fails hard. Re-run `sudo ./install.sh` to refresh the unit.

`t2fanrd` logs the limits it parsed at startup (`min_speed`, `max_speed`) — read
them there (`journalctl -u t2fanrd -b`) rather than assuming a figure. On
iMac20,2 under the 7.2 t2 kernels, cold-boot starts log `max_speed: 2700`,
but some later restarts (after a resume, or by `install.sh`) have logged 3600.
`fan1_max` reads whatever the running daemon logged.

**Fans spinning at full speed:**
T2 kernel patches not active — check the T2Linux patched kernel is installed and
that `t2fanrd.service` is enabled and running.

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

**How the installer treats an existing `/etc/t2fand.conf`:**

| Existing file | Action |
| --- | --- |
| absent | created at `60/90` |
| already `60/90` | left alone |
| `55/75` or `55/85` — bands older versions of this installer shipped | backed up, rewritten to `60/90` |
| `[fan1]` header, or `low_temp`/`high_temp` missing | backed up, rewritten — the daemon could not read the file, so there was no tuning to keep |
| any other thresholds | kept, with a warning; use `--force-fan-conf` to reset |

Earlier versions skipped the file whenever it existed, which let a stale band
survive every re-install.

**Fan too loud under light CPU load:**
`speed_curve = exponential` is cubic over the CPU *package* temperature:
`speed = min + (max-min)·((T-low)/(high-low))³`. With a narrow band the fan
saturates almost immediately — on iMac20,2 with `low=55 high=75`, one busy
thread gave 2673 RPM and two gave full speed (measured 2026-07, when the
daemon's `max_speed` was 3600 — cold-boot starts have logged 2700 since 2026-08). Widen the band; `low_temp=60`,
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

## Slow resume from suspend

On iMac20,2 every S3 resume used to stall for **10.1 s** before any device
came back. It was the same on every kernel from 7.1.8 to 7.2.8 and on all 102
resumes in the journal. The stall is in the kernel's noirq resume phase. A
per-device trace (`/sys/power/pm_print_times`) and an AML method trace put it
in Apple's ACPI `_PS0` power-on methods:

| Device | ACPI method | Time | What it waits for |
| --- | --- | --- | --- |
| `07:00.0` Thunderbolt upstream port | `RP05.UPSB._PS0` | 5.39 s | Two `CRMW` calls: router register writes through the PCIe2CIO mailbox, 5 reads × 394 ms polling + 5 × 100 ms sleeps each |
| `09:00.0` Thunderbolt NHI | `UPSB.DSB0.NHI0._PS0` | 2.47 s | One more `CRMW` (via `CTBT`) |
| `0a:00.0` Thunderbolt xHCI | `UPSB.DSB2.XHC2._PS0` | 1.16 s | 1 s for DSB2's link-training bit to clear, then 150 ms |
| `00:1c.0` Wi-Fi root port | `RP01._PS0` (and `_PS3` on suspend) | 1.01 s | 1 s for the Wi-Fi link to come up (go down, on suspend) |

Each of these does its work only `If (OSDW ())`, which means "the OS is
macOS". Linux answers `_OSI("Darwin")` on Apple hardware, so the firmware runs
its macOS power sequencing on every wake. Under Linux the waits can never
finish:

- All 15 mailbox reads timed out, so `CRMW` never wrote anything.
- XHC2 never saw the link-training bit clear, although the link is up.

The 9 s is pure timeout.

**The fix.** `install.sh` patches Apple's `TbtOnPCH` table from the live firmware
and loads it through `/boot/acpi_override.img`:

- `CRMW` returns its failure value at once, the result it always produced.
- XHC2's link wait gets a zero deadline. Its 150 ms settle delay stays.

Everything else in the table is untouched. That includes UPSB's 0.44 s link
retrain, which does work and leaves the link at 8 GT/s x4. None of these
devices runtime-suspend, so the methods run only on system resume.
`t2-tbt-acpi-patch.py` refuses any table whose bytes it does not recognise.
After a firmware update the installer leaves the patch out until a boot has
shown the new table.

For the Wi-Fi port there is nothing to patch short of the DSDT. If you do not use
Wi-Fi, `install.sh --disable-wifi` removes the port at boot instead, so its two
1 s waits go with it. It also blacklists `brcmfmac`, which could not drive the
chip without Apple's firmware anyway.

**Measure a resume:**

```bash
journalctl -k -b -o json | jq -r 'select(.MESSAGE|test("Waking up from system sleep|EC: interrupt unblocked|resume devices took|PM: suspend exit")) | "\((._SOURCE_MONOTONIC_TIMESTAMP|tonumber)/1e6) \(.MESSAGE)"'
```

The gap between the first two lines is the noirq phase: 10.1 s before the fix,
about 0.68 s after it. Use the kernel's timestamp as above, not
`-o short-monotonic`: that shows when journald received each line, and the
resume lines arrive in one burst, so the gap reads as almost zero. Right after
a resume, `sudo dmesg` shows the kernel timestamps too.
For a per-device breakdown, write `1` to `/sys/power/pm_print_times` (as root)
before suspending; each device then logs `calling …` / `… returned 0 after N usecs`.

---

## Known issues

- On first-attempt GPU init failure, the screen may show a horizontal corruption artifact for ~15–20 seconds. The warmfix retries automatically and the driver loads correctly.
- After such an event, rebooting into macOS may trigger 1–2 crash reports (`remoted` watchdog) and one automatic reboot within the first 5 minutes. macOS then runs normally.
- Maximum resolution is 4K — 5K is not supported by `amdgpu`.

---

## Notes

- Developed on Fedora 43, iMac20,2 (EFI boot).
- Should work on other T2 Macs with AMD GPUs — feedback welcome.
- `t2fanrd` binary: SHA256 `32612f571e8de56497c7c36dc32b4f6ba85cd25888afd5bb25c6de735f5fe52f`, built with rustc 1.87.0 from [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD) before its April 2026 fixes. Upstream publishes no releases or tags, so there is nothing to check the hash against. It is only a fallback: on Fedora, install the t2linux COPR's `t2fanrd` package (`/usr/bin/t2fanrd`), a newer build that logs only to a terminal instead of flooding the journal, and the installer uses it instead.
