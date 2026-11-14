# Linux fixes for Intel T2 Macs

An Intel Mac with Apple's T2 chip runs Linux with the t2linux kernel, but some
things still go wrong: the graphics card may not start, the fan can roar or
stay loud after sleep, waking from sleep is slow, plugged-in USB devices can
go unnoticed, the iMac's speakers sound odd and its microphone is too quiet.
This repo fixes those with
one installer, and installs each model-specific part only on hardware that
needs it.

Developed and tested on an **iMac20,2** (i7-10700K, Radeon Pro 5700). Most of
it should work on other T2 Macs with an AMD GPU.

**Tested on:** Fedora 43 and 44, t2linux kernels 7.1.x–7.3.x. A t2linux kernel
must already be installed.

| What you notice | What the fix does | Details |
| --- | --- | --- |
| Black screen or no graphics acceleration after boot, or a corrupted screen for 15–20 s | Brings the AMD GPU up reliably on every boot | [The GPU does not start reliably](#the-gpu-does-not-start-reliably) |
| Fan loud at idle, loud after waking from sleep, or roaring under light load | Runs the fan daemon with a sensible curve and keeps it in control | [Fan noise](#fan-noise) |
| Waking from sleep takes about 10 s | Cuts about 9 s of it, and the rest with Wi-Fi turned off | [Slow wake from sleep](#slow-wake-from-sleep) |
| A USB device you plug in does not show up | Keeps the USB hubs awake | [USB devices not appearing](#usb-devices-not-appearing) |
| iMac speakers: voices muffled or from one side, music hollow | Adds a proper stereo speaker output | [Speakers sound wrong](#speakers-sound-wrong-imac20x) |
| iMac microphone: others barely hear you, dictation drops words | Adds an amplified microphone input | [Microphone too quiet](#microphone-too-quiet-imac20x) |
| iMac 5K screen: flickering lines around the mouse pointer | Draws the pointer in software | [Lines around the pointer](#lines-around-the-pointer-imac20x) |

---

## The GPU does not start reliably

**What you see:** on some boots the screen stays black, or the desktop comes
up without graphics acceleration. A boot can also show a band of corrupted
picture for 15–20 s before the screen recovers. Starting from power off is the
worst case: on iMac20,2, 18 of 29 such boots had the GPU fail its first start.

**Why:** Apple's ACPI tables leave out power methods the Linux `amdgpu` driver
expects, so the GPU's PCI link can come up in an undefined state. On iMacs with
a Navi 10 GPU (Radeon Pro 5700 / 5700 XT) the GPU's power-management
controller can also hang at start-up; on iMac20,2 it did on most cold starts.

**What the fix does:** five steps, from earliest to latest in the boot:

| Layer | What | When | Why |
| --- | --- | --- | --- |
| **ACPI override** | Injects `_PR3`/`_DSM` stubs into the GPU ACPI device | Early initrd (before kernel) | Apple's ACPI tables omit the power-resource and device-specific methods the Linux AMDGPU driver expects; without them the PCI link comes up in an undefined state and the driver fails to initialize |
| **modprobe.d** | Sets `amdgpu.aspm=0`, `amdgpu.runpm=0`, `snd_hda_intel.power_save_controller=0`, blacklists `radeon`; on Navi 10 iMacs also `amdgpu.ppfeaturemask=0xfff7bffd` | Module load | Keeps amdgpu from setting up ASPM itself and disables runtime power management, so neither GPU function can be powered down after its driver claims it; blacklisting `radeon` prevents it from racing `amdgpu`. On Navi 10 iMacs the feature mask keeps the GPU's power-management controller from hanging on cold boots, so the GPU comes up on its first probe. Neither this nor `pcie_aspm=off` turns off the ASPM L1 that Apple's firmware enables on the GPU link |
| **udev rule** | Pins GPU PCI functions to `power/control=on`; sets the DPM level (`low` unless changed, see [GPU performance level](#gpu-performance-level)) | Device bind / driver load | PCIe runtime PM can suspend the GPU between the ACPI fix and the driver binding; pinning the power state to `on` closes that window. |
| **Warmfix service** | PCI remove → rescan with retry + readiness check; skipped when amdgpu's cold probe already succeeded, which on Navi 10 iMacs is now the normal case | systemd, before display manager | Forcing the PCI bus to re-enumerate the GPU slot makes the kernel re-read its BARs and re-run PCI init cleanly; the retry handles the ~15 s corruption case where the first init attempt fails |
| **DM drop-in** | Ensures display manager starts only after warmfix | systemd ordering | Without explicit ordering, GDM can race the warmfix and start against an uninitialised GPU, producing a black screen or failed compositor |

On iMac20,2 the GPU now comes up on its first try (9 of 9 cold boots
tested), so the warmfix normally only confirms that and steps aside. It stays
installed as the safety net.

Trade-offs:

- The GPU runs at its lowest clock by default: cool and quiet, but slow in
  games. One command changes that: see [GPU performance level](#gpu-performance-level).
- On Navi 10 iMacs the memory clock no longer scales up (see [Known issues](#known-issues)).
- `amdgpu.conf` keeps the GPU's HDMI/DP audio function powered. tuned's stock
  `balanced` and `powersave` profiles undo that, so the installer adds a small
  override for each.

## Fan noise

**What you see:** one of these:

- The fan is loud at idle and rises and falls with no link to what the
  computer is doing.
- The fan is fine until the Mac wakes from sleep, then stays loud.
- One or two busy programs are enough to send the fan to full speed.

**Why:** without a fan daemon, the T2's firmware drives the fan from chassis
sensors, not from the CPU. The daemon (`t2fanrd`) takes over, but the firmware
takes control back across every sleep. Older setups also wrote the daemon's
config to a file it never reads, and used a temperature band so narrow that
the fan saturated almost at once.

**On t2 kernels 7.3 and later** the SMC has a new driver, `macsmc`, and the
picture changes. The firmware's own curve was measured quiet at idle and after
sleep, follows the GPU as well as the CPU, and reaches the fan's full speed
under sustained load. So the fix leaves the fan to it there. It also keeps the
old `applesmc` driver from loading, which on those kernels fails after hanging
for almost two minutes at boot and stops the fan daemon from ever starting.
The same install still runs the daemon when you boot an older kernel.

**What the fix does on 7.2 and older kernels:**

- Uses the t2linux `t2fanrd` package when it is installed, or a bundled build
  otherwise.
- Writes `/etc/t2fand.conf` (the path the daemon actually reads) with a
  60–90 °C curve. It replaces bands this project used to ship and leaves any
  other values you set alone.
- Restarts the daemon after every wake so it takes the fan back.
- Waits for the fan's control file before starting the daemon, instead of
  failing and handing the fan back to the firmware.

Checks and fixes are under [Troubleshooting](#troubleshooting).

## Slow wake from sleep

**What you see:** after waking the Mac from sleep, about 10 seconds pass
before the screen and keyboard respond.

**Why:** Apple's firmware runs its macOS power-up steps for the Thunderbolt
controller and the Wi-Fi port on every wake. Under Linux those steps wait for
replies that never come, and only give up on timeouts.

**What the fix does:** the installer patches Apple's Thunderbolt table from
the live firmware, so its waits end at once, which saves about 9 s. If you do
not use Wi-Fi, `install.sh --disable-wifi` also removes the Wi-Fi port and its
1 s wait on both sleep and wake. With both, a wake on iMac20,2 went from
10.1 s to 0.68 s. See
[Wake from sleep: the patch in detail](#wake-from-sleep-the-patch-in-detail).

## USB devices not appearing

**What you see:** a USB device you plug in, such as a USB-to-Ethernet adapter,
never shows up in `lsusb` or in the desktop, and nothing is logged.

**Why:** the T2's USB root hubs go to sleep aggressively, and a sleeping hub
stops reporting new devices.

**What the fix does:** a udev rule keeps the USB root hubs awake.

## Speakers sound wrong (iMac20,x)

**What you see:** in videos, voices sound muffled or seem to come from one
set of speakers only; music sounds hollow.

**Why:** the iMac's speakers appear to Linux as one 4-channel output, and
t2linux-audio has no speaker tuning for these models, so stereo and 5.1 sound
are spread over the channels the wrong way.

**What the fix does:** adds an **iMac Speakers** stereo output that sends left
and right to the right drivers. Choose it once as your output. See
[Speaker output in detail](#speaker-output-in-detail).

---

## Microphone too quiet (iMac20,x)

**What you see:** in calls people barely hear you; dictation or speech
recognition misses words or whole sentences, because it takes your voice for
silence.

**Why:** the T2 chip passes the microphones to Linux raw, with no gain control.
macOS amplifies them in its own audio processing, and t2linux-audio does the
same for each MacBook, but it has no microphone profile for the iMac. Your
voice arrives about 40 dB too low. This is the same on every T2 Mac of this
kind, not a faulty microphone: on iMac20,2 all three microphone capsules work.

**What the fix does:** adds an **iMac Microphone** input that amplifies the
built-in microphone by 40 dB, with a limiter so loud sounds do not distort.
Choose it once as your input. The filter needs two packages, `lv2-swh-plugins` and `pipewire-module-filter-chain-lv2` (`sudo dnf install lv2-swh-plugins pipewire-module-filter-chain-lv2`). The installer skips the filter without them, and `amdgpu-check.sh` reports it if one goes missing later. See
[Microphone input in detail](#microphone-input-in-detail).

---

## Lines around the pointer (iMac20,x)

**What you see:** with GNOME on a t2 kernel from 7.2.9 on, thin flickering
lines around the mouse pointer and around what you click, in one half of the
screen.

**Why:** these kernels drive the 5K panel as two 2560×2880 halves, and the
graphics card's hardware pointer draws those lines there. Older kernels show
one 3840×2160 screen at most and are not affected.

**What the fix does:** makes GNOME draw the pointer itself
(`/etc/environment.d/90-t2-sw-cursor.conf`). It takes effect at your next
login.

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
2. Install all `*.service` units to `/etc/systemd/system/`, or, when the t2linux
   `t2fanrd` package is installed, use its unit with a drop-in and retire this
   repo's copy
3. Auto-detect the AMD GPU PCI slot and generate `/usr/local/bin/amdgpu-pci-reset-load.sh`
4. Install scripts to `/usr/local/bin/`, plus the bundled `t2fanrd` binary when the t2linux `t2fanrd` package is not installed
5. Install `modprobe.d`, `udev`, and `dracut` config files, and only where they
   apply: the Navi 10 feature mask, the stereo speaker and microphone filters,
   the iMac20,x software cursor and the tuned overrides
6. Create `/etc/t2fand.conf`, or reconcile an existing one (see below), and
   restart a running `t2fanrd` so the change takes effect
7. Enable `amdgpu-warmfix`, `t2fanrd`, `t2fanrd-resume`, and `applesmc-late` services
   (on 7.3+ kernels `t2fanrd` and `applesmc-late` skip themselves at start)
8. Create a display manager drop-in so the DM starts after warmfix
9. End with an "Action required" list of only the steps this system still
   needs (GRUB edits, `grubby`, `dracut`, reboot), or "No action required"

Existing files are backed up as `<file>.bak.YYYYMMDD-HHMMSS` before replacement.
The generated tuned overrides are the exception: a backup would only hold an
older generated copy. Re-running the installer changes nothing that is already
up to date.

> **Note:** The T2Linux patched kernel (providing the T2 bridge driver, `t2bce_core` or `apple_bce` on older kernels, and `applesmc`, or `macsmc` from 7.3 on) must already be installed.

### GRUB configuration (required)

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

Also remove `nomodeset` from that line if present: it keeps `amdgpu` from
probing the GPU. The installer counts `nomodeset` as a problem only when no `amdgpu.modeset=<value>` word is on the same command line. (`amdgpu.modeset=0` does not disable `amdgpu` on current
kernels. The parameter only overrides `nomodeset`, and any value given,
`0` included, re-enables it.)

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
sudo grubby --update-kernel=ALL --remove-args=nomodeset   # unless you also pass amdgpu.modeset=...
```

The installer's closing "Action required" list gives the exact commands for your system, and only the ones still needed.

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

**2. Kernel cmdline** (`acpi_override.img` never shows here: GRUB loads it as an
early initrd, not as a parameter):

```bash
grep -oE 'pci=noaer|pcie_aspm=off|amdgpu\.aspm=0|amdgpu\.runpm=0' /proc/cmdline
# want all four
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
System falls back to framebuffer (no acceleration). `amdgpu-warmfix` does not run on such a boot, unless an `amdgpu.modeset=` override is also set (then amdgpu probes and the warmfix runs as usual).

**Black screen (without `nomodeset`):**
Check that `/boot/acpi_override.img` exists, confirm GRUB params are set, regenerate `grub.cfg`.

**GPU not detected after boot:**
Run `sudo amdgpu-check.sh` — it will report the state of each layer and offer to restart the warmfix service live.

**Wrong PCI slot targeted:**
The GPU is usually at a fixed slot (e.g. `0000:03:00.0` VGA, `0000:03:00.1` audio).
Verify with `lspci -nn | grep VGA`. The installer detects the slot on every run, so re-run `sudo ./install.sh` after a hardware change; a manual edit of `/usr/local/bin/amdgpu-pci-reset-load.sh` is overwritten by the next install.

**Fan loud and unrelated to CPU load** (ramps at idle, ignores a cool package),
on 7.2 and older kernels: `t2fanrd` is not running, so the SMC is driving the
fan on its own firmware curve — which follows chassis/ambient sensors, not the
CPU package. On 7.3 and later the SMC's curve is the intended set-up, and
`t2fanrd` and `applesmc-late` show as skipped; `amdgpu-check.sh` says which
case applies.

`amdgpu-check.sh` reports all of this under "Fan daemon". By hand:

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
`fan1_max` reads whatever the running daemon logged. With 2700 the fan stops
~900 RPM short of what the SMC allows under all-core load. Current T2FanRD
reads the limit only from the SMC; a `max_speed=` line in `/etc/t2fand.conf`
needs a build that supports it, and the packaged one ignores it.

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
# verify the display manager has the drop-in (gdm.service.d/10-amdgpu-warmfix.conf on GNOME):
systemctl show display-manager.service -p DropInPaths
```

---

## GPU performance level

The udev rule holds the GPU at DPM level `low` (300 MHz core) unless told
otherwise. That is cool and quiet, but games and compute get a fraction of the
GPU. To let the driver scale the clock with load:

```bash
sudo t2-gpu-dpm.sh auto      # saved for every boot, applied now
t2-gpu-dpm.sh                # show the saved and the live level
sudo t2-gpu-dpm.sh low       # back to the default
```

Measured on iMac20,2 (Radeon Pro 5700), `glmark2` terrain at 2560×1440:

| Level | Idle | Under load | FPS | Junction after 5 min |
| --- | --- | --- | --- | --- |
| `low` | 10 W, 42 °C | 23 W, 300 MHz | 125 | — (49 °C at 60 s) |
| `auto` | 10 W, 42 °C | 45 W, 1350 MHz | 176–181 | 66 °C (critical 105 °C) |

`auto` costs nothing at idle: the core sleeps between frames. `low` came from
the t2linux hybrid-graphics guide's advice for MacBook dGPUs; nothing on this
iMac needed it. On 7.2 and older kernels the fan daemon follows the GPU temperature only when it finds the GPU's sensor, which the packaged T2FanRD does not do at boot (see CLAUDE.md, "Fan daemon config path"); in the 5-minute run the GPU stayed below the fan curve's 60 °C start until the last 30 s. On 7.3+ kernels the SMC's own curve drives the fan and reads the GPU die temperature: under a 45 W GPU load the fan stayed at 1200 RPM for about 290 s, then rose to about 2000.

`high` holds the top clock even at idle and was not measured. If LACT's
daemon (`lactd`) is enabled, it sets this level too; use LACT instead.

---

## Wake from sleep: the patch in detail

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

## Speaker output in detail

On iMac20,x the T2 card's speaker output has 4 channels, labelled front-left,
front-right, rear-left and rear-right. They are two sets of drivers in the
same speakers, not front and rear speakers, and t2linux-audio has no speaker
profile (EQ, crossover) for these models. Sound sent straight to them comes out
wrong:

- **5.1 video:** the dialogue channel goes to the "front" set and the surround
  channels to the "rear" set. Voices sound muffled, or as if they come from one
  set only.
- **Stereo:** PipeWire's default upmix sends the "rear" set only the difference
  between left and right, delayed 12 ms, which sounds hollow.

The installer adds a WirePlumber filter
(`/etc/wireplumber/wireplumber.conf.d/50-t2-stereo-speakers.conf`). It creates
a stereo **iMac Speakers** output that mixes everything to stereo, then sends
left to both left channels and right to both right channels. It also renames:

| Device | Name |
| --- | --- |
| Sound card | iMac Built-in Audio |
| 4-channel speaker output | Raw Speakers (do not use) |
| Headset microphone (jack) | Headset Microphone (jack) |

GNOME Settings labels devices "port – card", so it shows the new card name, for
example "Internal Speakers – iMac Built-in Audio". Apps that list outputs
themselves show the names above.

It takes effect at the next login, or after `systemctl --user restart wireplumber`.
Then:

- Choose **iMac Speakers** as the output once if it is not already the default:
  WirePlumber remembers earlier choices, and the raw output may be one of them.
- Leave **Raw Speakers** at 100% and use the iMac Speakers volume. It is kept
  visible so its volume can still be changed.
- Switching the card to a headphones profile removes iMac Speakers along with
  the raw output, so nothing is left pointing at a missing device.

Checked on iMac20,2 by recording the raw output's monitor while playing 440 Hz
left and 880 Hz right: each left channel carried only 440 Hz and each right
channel only 880 Hz, at equal levels.

---

## Microphone input in detail

The built-in microphone appears as one 3-channel source, one channel per
capsule, with no capture gain control: speech arrives around −50 dBFS. On
iMac20,2:

- **AUX0 and AUX1** carry nearly the same sound (correlation 0.93): two
  capsules close together. AUX1 also has a constant DC offset.
- **AUX2** works, but picks up a different signal (correlation about −0.2),
  likely a capsule farther away. Mixed in without a beamformer it would blur
  the voice, so the filter leaves it out.

The installer adds a WirePlumber filter
(`/etc/wireplumber/wireplumber.conf.d/51-t2-mic.conf`). It creates a mono
**iMac Microphone** input: the mean of AUX0 and AUX1, amplified by 40 dB,
with a 90 Hz high-pass that removes the DC offset and room rumble, and a
limiter at −1 dBFS. The raw source is renamed **Raw Microphone (do not use)**.
The limiter comes from `lv2-swh-plugins` and `pipewire-module-filter-chain-lv2`.
Nothing pulls them in any more, so install them yourself
(`sudo dnf install lv2-swh-plugins pipewire-module-filter-chain-lv2`). The
installer skips the microphone filter without them, and `amdgpu-check.sh`
flags them if they go missing later (a `dnf autoremove` removed one).

It takes effect at the next login, or after `systemctl --user restart wireplumber`.
Then:

- Choose **iMac Microphone** as the input once if it is not already the
  default: WirePlumber remembers earlier choices.
- Leave **Raw Microphone** at 100%; the gain is all in the filter.
- A microphone filter set up elsewhere for the same purpose (Handy's
  `imac-t2` filter, for example) is no longer needed: turn it off, so only one
  amplified input is left to choose from.

Checked on iMac20,2: the gain measured exactly +40.0 dB against the raw
source, and with the limit set to −20 dB for the test, peaks stopped at
−20.00 dBFS. With the same gain, dictated speech peaked near −5 dBFS, about
22 dB above the room noise, and a long test dictation came out complete.

To record the raw channels yourself, give the channel map:
`pw-record --target alsa_input.pci-0000_04_00.3.HiFi__Mic__source --channels 3 --channel-map AUX0,AUX1,AUX2 raw.wav`.
Without it, `parecord` remixes the channels and AUX2 comes back as all zeros.

---

## File overview

### Installer

| File | Description |
| --- | --- |
| `install.sh` | Main installer — runs all steps below |
| `uninstall.sh` | Removes all installed files, disables services, then prints the GRUB and initramfs cleanup steps this system still needs. `--all` also removes `/boot/acpi_override.img`, `/etc/t2fand.conf`, `/etc/t2-pci-amdgpu.conf` and `/var/lib/t2-pci-amdgpu`, but keeps the image while GRUB still loads it: GRUB loads no initramfs at all when one of its files is missing, and the system would not boot. `--dry-run` previews everything. If you choose not to restore a backup, the backups are kept, since one may hold your pre-install original; when you restore one, the others are removed. |
| `t2-grub-common.bash` | GRUB helpers sourced by both scripts (not installed) |
| `t2-tuned.bash` | tuned override helpers sourced by both scripts (not installed) |
| `amdgpu-reset-pci-template` | Template for the PCI reset script; `ADDR` is replaced with the detected slot at install time |

### Systemd units

| File | Installed to | Description |
| --- | --- | --- |
| `amdgpu-warmfix.service` | `/etc/systemd/system/` | Runs the PCI reset at boot, before the display manager, if amdgpu's cold probe failed. Skips itself when `nomodeset` is set without an `amdgpu.modeset` override. |
| `t2fanrd-dropin.conf` | `/etc/systemd/system/t2fanrd.service.d/10-t2-pci-amdgpu.conf` | When the t2linux `t2fanrd` package is installed (`/usr/bin/t2fanrd`): adds to the package's own unit the wait for the fan attribute, `RestartSec=5`, ordering after `applesmc-late`, and handing the fan back to the SMC on stop. It also skips the daemon on 7.3+ kernels (`macsmc_acpi`), where the SMC drives the fan. The package's sandboxed unit and newer build are used as they are. |
| `t2fanrd.service` | `/etc/systemd/system/` | Fallback without the package: runs the bundled T2 fan daemon (it also skips itself on 7.3+ kernels) |
| `t2fanrd-resume.service` | `/etc/systemd/system/` | Restarts `t2fanrd` after resume — the SMC drops manual fan control across S3, so without this the fan runs loud until the daemon is restarted by hand. On 7.3+ kernels the daemon is not running, so this restarts nothing |
| `applesmc-late.service` | `/etc/systemd/system/` | Loads `applesmc` once the T2 bridge driver has bound (`t2bce_core`; `apple-bce` before the 7.1 t2 kernel). Skips itself on kernels with `macsmc_acpi` (t2 7.3+), where `applesmc` must not load |

None of these units order themselves after `systemd-udev-settle.service`. It is
deprecated — systemd logs `systemd-udev-settle.service is deprecated. Please fix
<unit> not to pull it in` and names the offenders — it cost 0.77 s of boot on
iMac20,2, and draining the coldplug queue never actually guaranteed that the
device a given unit needs is present. Each unit now waits on its own precondition:
the T2 bridge binding, the `fan1_manual` attribute, or the GPU's PCI node.

### Scripts and binaries

| File | Installed to | Description |
| --- | --- | --- |
| `amdgpu-check.sh` | `/usr/local/bin/` | Health check: render node, module state, installed kernels with the broken `imac5k_table` quirk, PCI power state, warmfix log, GPU DPM level/clocks/temperatures/power, the Navi 10 feature mask in effect, HDMI/DP audio (including whether a tuned profile turned its power saving back on, and which file did), the fan daemon (binary, restarts, `fan1_manual`, RPM and the daemon's speed limit) and the tuned profile. Offers live warmfix re-trigger if GPU is missing (requires root). |
| `t2-gpu-status.sh` | `/usr/local/bin/` | Quick GPU and service status snapshot |
| `amdgpu-pci-reset-load.sh` | `/usr/local/bin/` (generated) | The warmfix itself, generated from `amdgpu-reset-pci-template` for the detected GPU slot; run by `amdgpu-warmfix.service` |
| `t2-unit-state.sh` | `/usr/local/bin/` | Unit list and per-unit state (`ran-once`, `not-run`, …) shared by `amdgpu-check.sh` and `t2-gpu-status.sh` |
| `t2-amd-nodes.sh` | `/usr/local/bin/` | Lists the DRM nodes under an AMD VGA function; shared by `amdgpu-check.sh` and `t2-gpu-status.sh` |
| `t2-facts.sh` | `/usr/local/bin/` | Facts `install.sh` and `amdgpu-check.sh` both judge: the Navi 10 iMac GPU IDs, the mic filter's LV2 packages, and whether the kernel has `macsmc_acpi` |
| `t2-tuned-audio.sh` | `/usr/local/bin/` | Prints what a tuned profile (the active one by default) does to `snd_hda_intel power_save_controller`, and which profile file decides it. Uses tuned's own loader, so includes and unit priorities resolve as in tuned. Called by `amdgpu-check.sh` and `install.sh` |
| `t2-gpu-dpm.sh` | `/usr/local/bin/` | Shows or sets the GPU's DPM level (`low`, `auto`, `high`). Setting it saves `T2_GPU_DPM` in `/etc/t2-pci-amdgpu.conf` for every boot and applies it at once. See [GPU performance level](#gpu-performance-level) |
| `t2-wait-sysfs.sh` | `/usr/local/bin/` | Blocks until a sysfs path matching any given glob appears. Used as `ExecStartPre=` in place of `udevadm settle` — waits for the one device the unit needs instead of the whole coldplug queue |
| `t2fanrd` | `/usr/local/bin/` | Fallback without the package: prebuilt T2 fan controller daemon — [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD). With the package installed, the installer removes any copy here (backed up) |

### Config files

| File | Installed to | Description |
| --- | --- | --- |
| `amdgpu.conf` | `/etc/modprobe.d/` | Sets `amdgpu.aspm=0` and `amdgpu.runpm=0` at module level; blacklists `radeon`; sets `snd_hda_intel.power_save_controller=0` so the GPU's HDMI audio function stays out of runtime suspend |
| `amdgpu-navi10-imac.conf` | `/etc/modprobe.d/` | Only on iMac20,x with a Navi 10 GPU (Radeon Pro 5700 / 5700 XT). Sets `amdgpu.ppfeaturemask=0xfff7bffd`, which keeps memory-clock scaling out of the power-management controller's start-up request. Without it, that controller hangs on most cold boots, and the GPU only came up after the warmfix's reset, ~6 s later and without HDMI/DP audio. With it, 9 of 9 cold boots came up first time. Cost: the memory clock cannot scale up under load. |
| `99-amdgpu-t2.rules` | `/etc/udev/rules.d/` | Pins the AMD VGA function to `power/control=on` at device bind; sets the DPM level saved in `/etc/t2-pci-amdgpu.conf` (`low` when there is none); records amdgpu's successful bind (`AMDGPU_WARMFIX_BOUND=1`) so the warmfix can stop waiting for the probe. Also targets the HDMI audio function, but that write is best-effort — `snd_hda_intel` resets it to `auto` when it binds, which is why the module option above exists |
| `99-t2-usb.rules` | `/etc/udev/rules.d/` | Pins USB root hubs (`idVendor=1d6b`, hub class `09`) to `power/control=on`. T2 xHCI hubs autosuspend aggressively and stop reporting device attach events; pinning the root hubs awake fixes USB-to-Ethernet adapters and similar devices not appearing in `lsusb`. |
| `99-t2-wifi-off.rules` | `/etc/udev/rules.d/` | Only with `install.sh --disable-wifi`. Removes the Wi-Fi (ACPI `ARPT`) and its root port from the PCI tree at boot, so Apple's 1 s link waits on that port no longer run on every suspend and resume. Bluetooth is unaffected — it is on the UART. |
| `t2-wifi-off.conf` | `/etc/modprobe.d/` | Only with `install.sh --disable-wifi`. Blacklists `brcmfmac`, which without Apple's firmware files only fails its probe and logs a `__flush_work` warning every boot. |
| `t2-audio-wireplumber.conf.in` | `/etc/wireplumber/wireplumber.conf.d/50-t2-stereo-speakers.conf` (generated) | Only on T2 Macs whose speakers are one 4-channel output and that have no t2linux-audio speaker profile (iMac20,x). Adds a stereo "iMac Speakers" output in front of it and gives the card, raw speaker output and headset mic clearer names. See [Speaker output in detail](#speaker-output-in-detail). |
| `t2-mic-wireplumber.conf.in` | `/etc/wireplumber/wireplumber.conf.d/51-t2-mic.conf` (generated) | Same Macs as the speaker filter. Adds an "iMac Microphone" input that amplifies the raw T2 microphone by 40 dB, with a high-pass and a limiter. See [Microphone input in detail](#microphone-input-in-detail). |
| `t2-applesmc.conf` | `/etc/modprobe.d/` | Blacklists `applesmc`'s automatic load on every kernel. `applesmc-late.service` loads it explicitly on kernels without `macsmc_acpi`. On 7.3+ kernels `applesmc` hangs for almost two minutes and then fails, so it must not load there. |
| `t2-sw-cursor.conf` | `/etc/environment.d/90-t2-sw-cursor.conf` | Only on iMac20,1 and iMac20,2. Sets `MUTTER_DEBUG_DISABLE_HW_CURSORS=1`, so GNOME draws the pointer in software. Takes effect at your next login. See [Lines around the pointer](#lines-around-the-pointer-imac20x). |
| `t2-tuned-hda.conf.in` | `/etc/tuned/profiles/<name>/tuned.conf` (generated) | Only when tuned is installed and the GPU has an HDMI audio function: one per stock profile with an `[audio]` section (`balanced`, `powersave`). Includes the stock profile and stops tuned from turning `snd_hda_intel power_save_controller` back on, which would let the GPU's HDMI audio function runtime-suspend. A same-name profile you wrote, or a generated one whose settings you edited, is left alone, and the installer says whether it still keeps the audio function awake. |
| `10-amdgpu-warmfix.conf` | `/etc/dracut.conf.d/` | Embeds `amdgpu`, `nvme` and `thunderbolt` in the initramfs via `force_drivers`. Every name must resolve to a real module — `force_drivers` makes a missing one a fatal `dracut -f` error |

### ACPI

| File | Description |
| --- | --- |
| `GFXALT-multi.aml` | Compiled ACPI SSDT — packed into `/boot/acpi_override.img` by the installer |
| `GFXALT-multi.dsl` | Source for the above. To recompile: `iasl -ve -tc GFXALT-multi.dsl` |
| `t2-tbt-acpi-patch.py` | Run by the installer: reads Apple's `TbtOnPCH` SSDT from `/sys/firmware/acpi/tables`, patches two methods, and the result goes into the same image. No Apple code is shipped in this repo. |

---

## Known issues

- On iMac20,x with a Navi 10 GPU the installer keeps memory-clock scaling off (`amdgpu-navi10-imac.conf`) so the GPU starts reliably. The memory clock then stays at its boot level, which limits games and compute.
- On a boot where the warmfix has to reset the GPU, HDMI/DP audio is lost until the next boot: the reset wipes the GPU's audio function. With the setting above this should no longer happen on Navi 10 iMacs.
- On first-attempt GPU init failure, the screen may show a horizontal corruption artifact for ~15–20 seconds. The warmfix retries automatically and the driver loads correctly.
- After such an event, rebooting into macOS may trigger 1–2 crash reports (`remoted` watchdog) and one automatic reboot within the first 5 minutes. macOS then runs normally.
- On the 7.2.8 t2 kernel the 5K panel is one `eDP-1` that tops out at 3840×2160. The 7.2.9 and later kernels drive it at 5120×2880 as two tiles. The 7.2.9-310.t2 and 7.2.15-310.t2 builds have an iMac quirk table (`imac5k_table`) with no terminator. The fc43 build of 7.2.9 oopsed the GPU probe on every boot, and the fc44 build booted only by luck. `amdgpu-check.sh` flags any installed kernel with the broken table, so avoid those builds. 7.3.3-310.t2 has the table intact, and 7.3.3 or later is fine. In tiled mode the hardware pointer draws flickering lines; the installer's software-cursor setting removes them (see [Lines around the pointer](#lines-around-the-pointer-imac20x)).
- In tiled 5K mode (7.2.9 and later, seen on iMac20,2) the kernel logs `dpcd_set_link_settings … failed` and `enabling link 1 failed: 15` at boot and at resume. Nothing has broken because of it so far. You may also see tearing at the seam between the two halves when things move, and a slight colour difference between the halves. The shutdown splash is drawn whole in each half.
- On 7.3+ kernels the SMC's clock is the system clock (`rtc_macsmc`), and it drifts about 4.5 s per day. A clock that was 21 minutes fast at boot was fixed once with `sudo hwclock --systohc`. NTP (chrony) corrects the rest at each boot.

---

## Notes

- Developed on Fedora 43, now running Fedora 44, iMac20,2 (EFI boot).
- Should work on other T2 Macs with AMD GPUs — feedback welcome.
- `t2fanrd` binary: SHA256 `32612f571e8de56497c7c36dc32b4f6ba85cd25888afd5bb25c6de735f5fe52f`, built with rustc 1.87.0 from [GnomedDev/T2FanRD](https://github.com/GnomedDev/T2FanRD) before its April 2026 fixes. Upstream publishes no releases or tags, so there is nothing to check the hash against. It is only a fallback: on Fedora, install the t2linux COPR's `t2fanrd` package (`/usr/bin/t2fanrd`), a newer build that logs only to a terminal instead of flooding the journal, and the installer uses it instead.
