#!/usr/bin/env bash
# install.sh — AMDGPU warmfix installer for Apple T2 iMac Intel
#
# Installs:
#   - ACPI override image            → /boot/acpi_override.img
#       GFXALT-multi.aml, plus Apple's Thunderbolt SSDT patched for S3 resume
#   - systemd service units          → /etc/systemd/system/
#   - GPU PCI reset script           → /usr/local/bin/ (generated from template)
#   - Helper scripts + t2fanrd       → /usr/local/bin/
#   - modprobe.d, udev, dracut files → respective system dirs
#   - Display manager drop-in        → warmfix runs before DM at boot
#   - iMac20,x speakers: stereo sink → /etc/wireplumber/wireplumber.conf.d/
#                                      (generated from t2-audio-wireplumber.conf.in)
#   - iMac20,x microphone: gain      → /etc/wireplumber/wireplumber.conf.d/
#                                      (generated from t2-mic-wireplumber.conf.in)
#   - iMac20,x: software cursor      → /etc/environment.d/90-t2-sw-cursor.conf
#   - tuned profiles with [audio]    → /etc/tuned/profiles/<name>/tuned.conf
#                                      (generated from t2-tuned-hda.conf.in)
#
# Usage: sudo ./install.sh [--dry-run] [--force-fan-conf] [--disable-wifi]
#
#   --dry-run          Show what would be installed without making changes
#   --force-fan-conf   Overwrite /etc/t2fand.conf with the shipped default even
#                      if its thresholds look hand-tuned
#   --disable-wifi     Remove the Wi-Fi and its root port from the PCI tree at
#                      boot (99-t2-wifi-off.rules) and blacklist brcmfmac
#                      (t2-wifi-off.conf); saves 1 s on every suspend and 1 s
#                      on every resume.  Only for machines that do not use Wi-Fi.
#
set -Eeuo pipefail
shopt -s nullglob

DRY_RUN=0
FORCE_FAN_CONF=0
DISABLE_WIFI=0
while (( $# )); do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --force-fan-conf) FORCE_FAN_CONF=1 ;;
    --disable-wifi)   DISABLE_WIFI=1 ;;
    # say/warn/err are not defined yet at this point in the file.
    *) printf "\033[1;31m[✗]\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
  esac
  shift
done

[[ "${DEBUG:-0}" == "1" ]] && { PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '; set -x; }
trap 'ec=$?; echo "[✗] FAILED at ${BASH_SOURCE##*/}:${LINENO} → ${BASH_COMMAND} (exit $ec)"; exit $ec' ERR

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()    { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn()   { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()    { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; }

backup() {
  [[ -e "$1" ]] || return 0
  if (( DRY_RUN )); then say "Would back up: $1"; return 0; fi
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$1" "$1.bak.$ts"
  say "Backed up: $1.bak.$ts"
}

# Files a --dry-run would have installed.  The closing "Action required"
# check treats them as changed now, so the preview lists the dracut and reboot
# steps the real install will need.
declare -A pending=()
# Files install_file/retire_file changed (or would change, under --dry-run),
# for the "log out" / "restart wireplumber" hints.
declare -A changed=()

# install_file SRC DST [MODE]  — backup DST if present, then install SRC → DST
#
# An identical DST (same bytes, same mode) is left alone.  Its mtime then still
# says when it last really changed, which the closing "Action required" check
# compares against the boot time and the initramfs.
install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ ! -f "$src" ]]; then
    warn "Not found, skipping: $src"
    return
  fi
  if [[ -f "$dst" ]] && cmp -s -- "$src" "$dst" \
     && [[ "$(stat -c %a -- "$dst")" == "${mode#0}" ]]; then
    say "Up to date: $dst"
    return 0
  fi
  if (( DRY_RUN )); then
    say "Would install: $src → $dst (mode $mode)"
    pending[$dst]=1 changed[$dst]=1
    return 0
  fi
  backup "$dst"
  install -Dm"$mode" "$src" "$dst"
  changed[$dst]=1
  say "Installed: $dst"
}

# retire_file PATH WHY — back PATH up, then remove it
retire_file() {
  [[ -e "$1" ]] || return 0
  changed[$1]=1
  if (( DRY_RUN )); then say "Would retire: $1 ($2)"; pending[$1]=1; return 0; fi
  backup "$1"
  rm -f -- "$1"
  say "Retired: $1 ($2)"
}

require_root() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || { err "Run with sudo/root."; exit 1; }
}

check_deps() {
  local missing=()
  for cmd in cpio systemctl modprobe udevadm realpath install; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || { err "Missing tools: ${missing[*]}"; exit 1; }
}

# fan_conf_get KEY FILE — read a "key=value" (or "key = value") from an ini file.
# Prints the value, or nothing if the key is absent.
fan_conf_get() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p" "$2" | head -1
}

write_fan_conf() {
  cat > "$1" <<'EOF'
# /etc/t2fand.conf — T2 fan daemon configuration
# Adjust low_temp/high_temp (°C) to suit your hardware.
# speed_curve: linear | exponential | logarithmic
# always_full_speed: true | false
#
# exponential is cubic: speed = min + (max-min) * ((T-low)/(high-low))^3
# T is the CPU *package* temperature (coretemp temp1_input).
#
# Defaults tuned for iMac20,2 (i7-10700K).  That chip sits at 90-100 °C under
# all-core load and the chassis cannot hold it lower at any RPM, so ending the
# curve below ~90 just means max fan for every real workload.
[Fan1]
low_temp=60
high_temp=90
speed_curve=exponential
always_full_speed=false
EOF
  chmod 0644 "$1"
}

enable_service() {
  local unit="$1"
  if (( DRY_RUN )); then say "Would enable: $unit"; return 0; fi
  # Ask systemd, not ${UNIT_DIR}: with the t2fanrd package the unit lives in
  # /usr/lib/systemd/system and only a drop-in is ours.
  if [[ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" == loaded ]]; then
    systemctl enable "$unit"
    say "Enabled: $unit"
  fi
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
DRACUT_DIR="/etc/dracut.conf.d"
ACPI_IMG="/boot/acpi_override.img"
STATE_DIR="/var/lib/t2-pci-amdgpu"
TBT_BIOS_FILE="${STATE_DIR}/TbtOnPCH.bios"

# GRUB_FILE, grub_cfg, boot_mode, REQUIRED_PARAMS, grub_var, has_word,
# boot_entry_args — shared with uninstall.sh.  Sourced before any change, so a
# copy missing this file stops here rather than half-installed.
[[ -f "${SRC_DIR}/t2-grub-common.bash" ]] || { err "Missing ${SRC_DIR}/t2-grub-common.bash"; exit 1; }
# shellcheck source=t2-grub-common.bash
source "${SRC_DIR}/t2-grub-common.bash"
# TUNED_*, tuned_is_ours, tuned_is_pristine, tuned_reload — shared with uninstall.sh.
for f in t2-tuned.bash t2-tuned-hda.conf.in t2-tuned-audio.sh; do
  [[ -f "${SRC_DIR}/$f" ]] || { err "Missing ${SRC_DIR}/$f"; exit 1; }
done
# shellcheck source=t2-tuned.bash
source "${SRC_DIR}/t2-tuned.bash"

require_root
check_deps
(( DRY_RUN )) && say "=== DRY RUN — no changes will be made ==="
say "AMDGPU warmfix installation — source: ${SRC_DIR}"

# ---------------------------------------------------------------------------
# 1) ACPI override image
# ---------------------------------------------------------------------------
# The image must be an UNCOMPRESSED cpio.  acpi_table_upgrade() scans the raw
# initrd for kernel/firmware/acpi/*.aml before anything is decompressed, so a
# compressed archive is silently skipped — no error, the SSDT just never loads.
# Installers before 2026-10 gzipped it, and every boot ran without layer 1.
#
# Two tables go in:
#   GFXALT-multi.aml  new SSDT with the GPU's _PR3/_DSM stubs (layer 1)
#   TbtOnPCH.aml      Apple's Thunderbolt SSDT with two resume waits that
#                     always time out under Linux cut out — 9 s of every S3
#                     resume on iMac20,2.  Generated from the live firmware
#                     table by t2-tbt-acpi-patch.py, which documents both edits.
#
# The image is rebuilt on every run and replaced only when its bytes differ.
acpi_img_compressed() {
  local magic
  magic="$(od -A n -t x1 -N 2 "$1" 2>/dev/null | tr -d ' \n')"
  [[ "$magic" == 1f8b ]]   # gzip; the newc cpio magic is "070701"
}

# acpi_table_by_id ID — path of the live SSDT whose OEM table ID (header bytes
# 16-23) is ID.  Root only: /sys/firmware/acpi/tables/* are mode 0400.
acpi_table_by_id() {
  local t
  for t in /sys/firmware/acpi/tables/SSDT*; do
    if [[ "$(head -c 24 "$t" 2>/dev/null | tail -c 8 | tr -d '\0')" == "$1" ]]; then
      printf '%s\n' "$t"
      return 0
    fi
  done
  return 1
}

# tbt_table DIR — write Apple's TbtOnPCH, patched for resume, into DIR.
# Returns 1, having said why, when it is left out.
#
# Once the override is active the live table IS the patched copy, which the
# patcher passes through unchanged.  That copy was made from the firmware
# recorded in TBT_BIOS_FILE.  After a firmware update it would replace a table
# nobody has checked, so it is left out instead: the next boot then runs the
# new firmware's own table, and the next install patches that one.
tbt_table() {
  local live out bios rec
  if ! live="$(acpi_table_by_id TbtOnPCH)"; then
    say "No Apple TbtOnPCH table on this Mac — Thunderbolt resume patch not needed"
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    warn "python3 not found — Thunderbolt resume patch left out (resume stays ~9 s slower)"
    return 1
  fi
  if ! out="$(python3 "${SRC_DIR}/t2-tbt-acpi-patch.py" "$live" "$1/TbtOnPCH.aml" 2>&1)"; then
    warn "Thunderbolt resume patch left out: ${out}"
    rm -f -- "$1/TbtOnPCH.aml"
    return 1
  fi
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null)" || bios=""
  if [[ "$out" == already* ]]; then
    rec="$(cat -- "$TBT_BIOS_FILE" 2>/dev/null)" || rec=""
    if [[ "$rec" != "$bios" ]]; then
      warn "Firmware is '${bios}', the Thunderbolt patch was made on '${rec:-unknown}' — leaving it out"
      warn "  Reboot, then re-run install.sh to patch the table this firmware ships."
      rm -f -- "$1/TbtOnPCH.aml"
      return 1
    fi
  else
    mkdir -p -- "$STATE_DIR"
    backup "$TBT_BIOS_FILE"
    printf '%s\n' "$bios" > "$TBT_BIOS_FILE"
  fi
  say "Thunderbolt resume patch: ${out}"
}

if (( DRY_RUN )); then
  say "Would rebuild $ACPI_IMG: GFXALT-multi.aml + Apple TbtOnPCH patched for resume"
else
  tmpdir="$(mktemp -d)"
  acpi_dir="$tmpdir/kernel/firmware/acpi"
  mkdir -p "$acpi_dir"
  if [[ -f "${SRC_DIR}/GFXALT-multi.aml" ]]; then
    # Fixed mode: cpio records it, so the checkout's mode would change the image.
    install -m0644 "${SRC_DIR}/GFXALT-multi.aml" "$acpi_dir/"
  else
    warn "GFXALT-multi.aml not found — GPU ACPI override left out (required for GPU fix)"
  fi
  tbt_table "$acpi_dir" || true
  tables=("$acpi_dir"/*.aml)
  if (( ${#tables[@]} == 0 )); then
    warn "No ACPI tables to install — $ACPI_IMG not written"
  else
    # Fixed mtimes and device-independent inodes: the same tables always give
    # the same bytes, so an unchanged image compares equal below.
    find "$tmpdir/kernel" -exec touch -h -d @0 {} +
    ( cd "$tmpdir" && find kernel | LC_ALL=C sort | cpio -H newc --quiet --reproducible -o ) > "$tmpdir/img"
    names="$(cd "$acpi_dir" && echo *.aml)"
    if [[ -f "$ACPI_IMG" ]] && cmp -s "$tmpdir/img" "$ACPI_IMG"; then
      say "ACPI override is up to date: $ACPI_IMG ($names)"
    else
      if [[ -f "$ACPI_IMG" ]] && acpi_img_compressed "$ACPI_IMG"; then
        say "Replacing gzip-compressed $ACPI_IMG — the kernel never read it"
      fi
      backup "$ACPI_IMG"
      install -m0644 "$tmpdir/img" "$ACPI_IMG"
      say "Installed: $ACPI_IMG ($names) — takes effect at the next boot"
    fi
  fi
  rm -rf -- "$tmpdir"
fi

# ---------------------------------------------------------------------------
# 2) Service units → /etc/systemd/system/
# ---------------------------------------------------------------------------
say "Installing service units"
# t2fanrd: the t2linux package's build and unit when installed, with this
# repo's additions as a drop-in.  This repo's own unit in ${UNIT_DIR} would
# replace the package's whole unit, sandboxing included, and its bundled
# binary predates upstream's fixes (journal flooding, averaging).
T2FANRD_DROPIN="${UNIT_DIR}/t2fanrd.service.d/10-t2-pci-amdgpu.conf"
t2fanrd_pkg=0
[[ -x /usr/bin/t2fanrd && -f /usr/lib/systemd/system/t2fanrd.service ]] && t2fanrd_pkg=1
for f in "${SRC_DIR}"/*.service; do
  if (( t2fanrd_pkg )) && [[ "$(basename "$f")" == t2fanrd.service ]]; then continue; fi
  install_file "$f" "${UNIT_DIR}/$(basename "$f")"
done
if (( t2fanrd_pkg )); then
  say "t2fanrd: using the packaged /usr/bin/t2fanrd and its unit"
  retire_file "${UNIT_DIR}/t2fanrd.service" "would hide the package's unit"
  install_file "${SRC_DIR}/t2fanrd-dropin.conf" "$T2FANRD_DROPIN"
else
  # Names /usr/bin/t2fanrd, which is gone with the package.
  retire_file "$T2FANRD_DROPIN" "the t2fanrd package is not installed"
fi

# ---------------------------------------------------------------------------
# 3) GPU PCI reset script (generated from template with detected slot address)
# ---------------------------------------------------------------------------
template="${SRC_DIR}/amdgpu-reset-pci-template"
target="${BIN_DIR}/amdgpu-pci-reset-load.sh"
if [[ -f "$template" ]]; then
  say "Detecting AMD GPU PCI slot"
  gpu_bdf="$(lspci -D -nn 2>/dev/null | awk '/VGA compatible controller/ && /\[1002:/{print $1; exit}')" || true
  if [[ -z "${gpu_bdf:-}" ]]; then
    gpu_bdf="$(for d in /sys/bus/pci/devices/*; do
      [[ -e "$d/vendor" && -e "$d/class" ]] || continue
      read -r ven < "$d/vendor"; read -r cls < "$d/class"
      [[ "$ven" == "0x1002" && "$cls" == 0x0300* ]] && { basename "$d"; break; }
    done)" || true
  fi
  [[ -n "${gpu_bdf:-}" ]] || { err "AMD VGA device not found (lspci and sysfs both failed)."; exit 1; }
  slot="${gpu_bdf%.*}"   # e.g. 0000:03:00
  slot="${slot#????:}"   # strip domain prefix → 03:00
  # Validate that both VGA (.0) and audio (.1) functions exist at this slot
  vga_dev="/sys/bus/pci/devices/0000:${slot}.0"
  aud_dev="/sys/bus/pci/devices/0000:${slot}.1"
  if [[ ! -e "$vga_dev" ]]; then
    err "VGA function not found at ${vga_dev}"; exit 1
  fi
  if [[ ! -e "$aud_dev" ]]; then
    warn "HDMI audio function not found at ${aud_dev} — warmfix will skip audio removal"
  fi
  say "Validated PCI slot: VGA=${vga_dev} Audio=${aud_dev}"
  gen="$(mktemp)"
  {
    cat <<'HDR'
#!/usr/bin/env bash
# amdgpu-pci-reset-load.sh — generated by install.sh; do not edit manually
set -Eeuo pipefail
log(){ echo "[amdgpu-warmfix] $*"; }
HDR
    sed "s/ADDR/${slot}/g" "$template"
  } > "$gen"
  install_file "$gen" "$target" 0755
  rm -f -- "$gen"
else
  warn "Template not found: $template — skipping GPU reset script"
fi

# ---------------------------------------------------------------------------
# 4) Scripts and binaries → /usr/local/bin/
# ---------------------------------------------------------------------------
say "Installing scripts to ${BIN_DIR}"
for f in "${SRC_DIR}"/*.sh; do
  # The installer and uninstaller stay in the repo — they are not runtime tools.
  case "$(basename "$f")" in install.sh|uninstall.sh) continue ;; esac
  install_file "$f" "${BIN_DIR}/$(basename "$f")" 0755
done

if (( t2fanrd_pkg )); then
  retire_file "${BIN_DIR}/t2fanrd" "superseded by the packaged /usr/bin/t2fanrd"
else
  install_file "${SRC_DIR}/t2fanrd" "${BIN_DIR}/t2fanrd" 0755
fi

# ---------------------------------------------------------------------------
# 5) System config files
# ---------------------------------------------------------------------------
if ! (( DRY_RUN )); then mkdir -p /etc/modprobe.d /etc/udev/rules.d "$DRACUT_DIR"; fi
install_file "${SRC_DIR}/amdgpu.conf"               "/etc/modprobe.d/amdgpu.conf"
# No DMI autoload of applesmc, so it never runs next to macsmc (t2 kernels from
# 7.3 on), where it hangs its loader for ~107 s.  applesmc-late.service loads
# it on the kernels that need it.  See t2-applesmc.conf.
APPLESMC_CONF=/etc/modprobe.d/t2-applesmc.conf
install_file "${SRC_DIR}/t2-applesmc.conf"          "$APPLESMC_CONF"
# Navi 10 iMac20,x boards: keep memory-clock DPM out of the SMU's init request,
# which their SMU hangs on (see amdgpu-navi10-imac.conf).  Matched on the exact
# device and Apple subsystem IDs: other T2 GPUs keep full memory-clock DPM.
NAVI10_IMAC_CONF=/etc/modprobe.d/amdgpu-navi10-imac.conf
navi10_imac=0
if [[ -n "${slot:-}" ]]; then
  gpu_ids=""
  for f in device subsystem_vendor subsystem_device; do
    gpu_ids+="$(cat "/sys/bus/pci/devices/0000:${slot}.0/$f" 2>/dev/null):"
  done
  case "$gpu_ids" in
    0x731b:0x106b:0x021a:|0x7319:0x106b:0x021b:) navi10_imac=1 ;;
  esac
fi
if (( navi10_imac )); then
  say "Navi 10 iMac GPU (${gpu_ids%:}): memory-clock DPM kept out of SMU init"
  install_file "${SRC_DIR}/amdgpu-navi10-imac.conf" "$NAVI10_IMAC_CONF"
else
  retire_file "$NAVI10_IMAC_CONF" "not a Navi 10 iMac GPU"
fi
install_file "${SRC_DIR}/99-amdgpu-t2.rules"        "/etc/udev/rules.d/99-amdgpu-t2.rules"
install_file "${SRC_DIR}/99-t2-usb.rules"           "/etc/udev/rules.d/99-t2-usb.rules"
if (( DISABLE_WIFI )); then
  install_file "${SRC_DIR}/99-t2-wifi-off.rules"    "/etc/udev/rules.d/99-t2-wifi-off.rules"
  install_file "${SRC_DIR}/t2-wifi-off.conf"        "/etc/modprobe.d/t2-wifi-off.conf"
elif [[ -f /etc/udev/rules.d/99-t2-wifi-off.rules || -f /etc/modprobe.d/t2-wifi-off.conf ]]; then
  say "Keeping the --disable-wifi files — Wi-Fi stays off. To bring it back, delete"
  say "  /etc/udev/rules.d/99-t2-wifi-off.rules and /etc/modprobe.d/t2-wifi-off.conf,"
  say "  run 'echo 1 | sudo tee /sys/bus/pci/rescan', and re-run this installer"
fi
# Speakers: T2 cards with the 4-channel speaker layout (UCM AppleT2x4) and no
# t2linux-audio DSP profile for the model (iMac20,x) get a stereo sink in
# front of the 4 channels, which are two driver pairs, not front and rear.
# See t2-audio-wireplumber.conf.in.
T2_SPEAKERS_CONF=/etc/wireplumber/wireplumber.conf.d/50-t2-stereo-speakers.conf
# The mic filter's limiter: file → package.  amdgpu-check.sh checks the same.
declare -A T2_MIC_LV2=(
  [/usr/lib64/lv2/fast_lookahead_limiter-swh.lv2/plugin-Linux.so]=lv2-swh-plugins
  [/usr/lib64/spa-0.2/filter-graph/libspa-filter-graph-plugin-lv2.so]=pipewire-module-filter-chain-lv2
)
t2_speakers_why=""
t2_audio_pci=""
t2_wp_changed=0
# t2_audio_card — print the PCI address (0000:04:00.3) of the AppleT2x4 card.
t2_audio_card() {
  local n
  # " 0 [Audio          ]: AppleT2x4 - Apple T2 Audio": the padded id splits
  # into several fields, so match the driver name, not a field number.
  n="$(awk '/\]: AppleT2x4 - / {print $1; exit}' /proc/asound/cards 2>/dev/null)"
  [[ -n "$n" ]] || return 1
  realpath "/sys/class/sound/card${n}/device" 2>/dev/null \
    | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' | tail -1
}
mac_model="$(cat /sys/class/dmi/id/product_name 2>/dev/null)" || mac_model=""
# t2linux-audio names its DSP profiles after the model number: iMac20,2 → 20_2.
dsp_dir="/usr/share/t2linux-audio/$(sed 's/[^0-9]*//; s/,/_/' <<<"$mac_model")"
if ! bdf="$(t2_audio_card)" || [[ -z "$bdf" ]]; then
  t2_speakers_why="no T2 audio card with the 4-channel speaker layout"
elif [[ -n "$mac_model" && -d "$dsp_dir" ]]; then
  t2_speakers_why="t2linux-audio has a speaker DSP profile for ${mac_model}"
elif [[ ! -f /usr/share/wireplumber/scripts/node/software-dsp.lua ]]; then
  t2_speakers_why="WirePlumber has no software-dsp support (needs 0.5)"
else
  t2_audio_pci="pci-${bdf//:/_}"
fi
mac_name="Mac"
case "$mac_model" in
  iMacPro*)     mac_name="iMac Pro" ;;
  iMac*)        mac_name="iMac" ;;
  MacBookPro*)  mac_name="MacBook Pro" ;;
  MacBookAir*)  mac_name="MacBook Air" ;;
  Macmini*)     mac_name="Mac mini" ;;
esac
# wp_conf TEMPLATE DEST NAME DESC [WHY] — generate DEST from TEMPLATE for this
# card and install it, or retire DEST when there is no card to fit
# (t2_audio_pci empty) or WHY says why not.
# Sets t2_wp_changed when DEST changes, for the "restart wireplumber" hint.
wp_conf() {
  local gen why="${5:-}"
  [[ -n "$t2_audio_pci" ]] || why="$t2_speakers_why"
  if [[ -n "$why" ]]; then
    say "T2 ${3}: no ${4} — ${why}"
    retire_file "$2" "$why"
    [[ -z "${changed[$2]:-}" ]] || t2_wp_changed=1
    return 0
  fi
  say "T2 ${3} (${mac_model}, ${bdf}): ${4}"
  gen="$(mktemp)"
  sed -e "s/@T2_AUDIO_PCI@/${t2_audio_pci}/g" -e "s/@MODEL@/${mac_name}/g" \
    "${SRC_DIR}/$1" > "$gen"
  install_file "$gen" "$2"
  rm -f -- "$gen"
  [[ -z "${changed[$2]:-}" ]] || t2_wp_changed=1
}
wp_conf t2-audio-wireplumber.conf.in "$T2_SPEAKERS_CONF" \
  speakers "stereo \"${mac_name} Speakers\" sink"
# Microphone: same Macs (no t2linux-audio profile, so no mic.json either).
# The raw T2 mic has no gain control and arrives ~40 dB low; a mono source
# in front of it adds the gain.  See t2-mic-wireplumber.conf.in.  Its limiter
# is LV2 (T2_MIC_LV2), and nothing installed depends on those packages any
# more: t2linux-audio 3.0 dropped lv2-swh-plugins, and a dnf autoremove then
# removed it.  A filter whose plugin is missing never starts, and the default
# source records silence, so without them there is no filter.
t2_mic_why=""
lv2_missing=()
for f in "${!T2_MIC_LV2[@]}"; do
  [[ -e "$f" ]] || lv2_missing+=("${T2_MIC_LV2[$f]}")
done
if [[ -n "$t2_audio_pci" ]] && (( ${#lv2_missing[@]} )); then
  t2_mic_why="missing ${lv2_missing[*]}"
  warn "T2 microphone: install the limiter, then re-run: sudo dnf install ${lv2_missing[*]}"
fi
wp_conf t2-mic-wireplumber.conf.in /etc/wireplumber/wireplumber.conf.d/51-t2-mic.conf \
  microphone "+40 dB mono \"${mac_name} Microphone\" source" "$t2_mic_why"
# Cursor: iMac20,x 5K panels are driven as two tiles on t2 kernels from 7.2.9
# on, and mutter's hardware cursor flickers there.  Matched on the model, not
# on the live tiling, so an install from a 7.2.8 boot (one eDP-1) still sets
# it; there it only costs the hardware cursor.  See t2-sw-cursor.conf.
SW_CURSOR_CONF=/etc/environment.d/90-t2-sw-cursor.conf
case "$mac_model" in
  iMac20,1|iMac20,2)
    say "iMac 5K (${mac_model}): software cursor in GNOME (tiled-panel flicker)"
    install_file "${SRC_DIR}/t2-sw-cursor.conf" "$SW_CURSOR_CONF"
    ;;
  *)
    retire_file "$SW_CURSOR_CONF" "not an iMac20,x 5K panel"
    ;;
esac
# tuned: shadow each stock profile with an [audio] unit, so it stops turning
# HDMI audio power saving back on.  See t2-tuned-hda.conf.in.  Our own files
# are not backed up: a backup would only hold an older generated copy.  One
# whose settings someone edited (tuned_is_pristine) is kept and judged like a
# user's file.
tuned_changed=0
tuned_why=""
[[ -n "${aud_dev:-}" && -e "${aud_dev:-}" ]] || tuned_why="no AMD HDMI audio function"
for stock in "${TUNED_STOCK_DIR}"/*/tuned.conf; do
  [[ -z "$tuned_why" ]] || break
  tuned_has_audio "$stock" || continue
  prof="$(basename "$(dirname "$stock")")"
  dst="${TUNED_ETC_DIR}/${prof}/tuned.conf"
  if [[ -e "$dst" ]] && ! { tuned_is_ours "$dst" && tuned_is_pristine "$dst" "$prof"; }; then
    if tuned_is_ours "$dst"; then whose="edited copy of our override"; else whose="own profile"; fi
    # Same verdict tuned would reach, includes and all (t2-tuned-audio.sh).
    read -r t_state _ < <("${SRC_DIR}/t2-tuned-audio.sh" "$prof" || true) || t_state=""
    case "$t_state" in
      off|none) say "tuned: keeping your ${whose} ${dst} (it leaves HDMI audio awake)" ;;
      on)  warn "tuned: keeping your ${whose} ${dst} — it resets power_save_controller to Y; set 'reset_controller=false' in its [audio] unit, or HDMI audio runtime-suspends" ;;
      bad) warn "tuned: keeping your ${whose} ${dst} — its reset_controller value is not a boolean the kernel takes; use false" ;;
      *)   warn "tuned: keeping your ${whose} ${dst} — could not load it with tuned to check its [audio] unit" ;;
    esac
    continue
  fi
  gen="$(mktemp)"
  tuned_generate "$prof" > "$gen"
  if ! cmp -s -- "$gen" "$dst"; then
    tuned_changed=1
    (( DRY_RUN )) || rm -f -- "$dst"   # pristine and ours: no backup (see above)
  fi
  install_file "$gen" "$dst"
  rm -f -- "$gen"
done
# Ours, but not needed here or the stock profile no longer touches audio.
for dst in "${TUNED_ETC_DIR}"/*/tuned.conf; do
  tuned_is_ours "$dst" || continue
  prof="$(basename "$(dirname "$dst")")"
  why="$tuned_why"
  if [[ -z "$why" ]]; then
    tuned_has_audio "${TUNED_STOCK_DIR}/${prof}/tuned.conf" && continue
    why="stock tuned profile '${prof}' has no [audio] unit"
  fi
  if ! tuned_is_pristine "$dst" "$prof"; then
    warn "tuned: not needed (${why}), but ${dst} was edited — keeping it; delete it by hand if unwanted"
    continue
  fi
  tuned_changed=1
  if (( DRY_RUN )); then say "Would remove: ${dst} (${why})"; pending[$dst]=1; continue; fi
  rm -f -- "$dst"
  rmdir --ignore-fail-on-non-empty -- "$(dirname "$dst")"
  say "Removed: ${dst} (${why})"
done
# Reload when an override changed (tuned keeps the profile it loaded until
# then), or when the live value is wrong anyway.
if systemctl is-active --quiet tuned.service; then
  if (( tuned_changed )) || [[ "$(cat "$HDA_PSC" 2>/dev/null)" == Y ]]; then
    tuned_reload
    if ! (( DRY_RUN )) && [[ -z "$tuned_why" && "$(cat "$HDA_PSC" 2>/dev/null)" == Y ]]; then
      warn "tuned: power_save_controller still reads Y — amdgpu-check.sh names the profile that sets it"
    fi
  fi
fi
install_file "${SRC_DIR}/10-amdgpu-warmfix.conf"    "${DRACUT_DIR}/10-amdgpu-warmfix.conf"
install_file "${SRC_DIR}/20-amdgpu-t2-cmdline.conf" "${DRACUT_DIR}/20-amdgpu-t2-cmdline.conf"
if ! (( DRY_RUN )); then
  udevadm control --reload-rules
  say "udev rules reloaded"
fi

# ---------------------------------------------------------------------------
# 6) Fan daemon config — created, or reconciled if an older one is in the way
#
# The path is NOT a choice: t2fanrd has /etc/t2fand.conf (no "r") compiled in
# and ignores --config.  Earlier versions of this installer wrote
# /etc/t2fanrd.conf, which the daemon never read — edits there did nothing.
# The section header must be [Fan1], capital F: the daemon looks up "Fan{i}".
#
# This step used to skip outright whenever the file existed, on the theory that
# the user may have tuned it.  That let a stale band shipped by an older
# installer survive every subsequent re-run — the 55/75 band pins an i7-10700K
# at max RPM from two busy threads, and no amount of re-installing fixed it.
# So: repair a file that is structurally dead, migrate thresholds this project
# is known to have shipped, and only leave genuinely hand-tuned values alone.
# ---------------------------------------------------------------------------
FAN_CONF="/etc/t2fand.conf"
FAN_LOW_DEFAULT=60
FAN_HIGH_DEFAULT=90
FAN_CURVE_DEFAULT=exponential
FAN_AFS_DEFAULT=false
# Bands previous versions of this installer wrote.  These are installer output,
# not a user's decision, so they get migrated rather than preserved.
FAN_LEGACY_BANDS=( "55/85" "55/75" )

if [[ -f /etc/t2fanrd.conf ]]; then
  warn "/etc/t2fanrd.conf exists but is never read by t2fanrd — safe to delete"
fi

if [[ ! -f "$FAN_CONF" ]]; then
  if (( DRY_RUN )); then
    say "Would create: $FAN_CONF (${FAN_LOW_DEFAULT}/${FAN_HIGH_DEFAULT})"
  else
    write_fan_conf "$FAN_CONF"
    warn "Default $FAN_CONF created — review thresholds for your hardware"
  fi
else
  fan_low="$(fan_conf_get low_temp  "$FAN_CONF")"
  fan_high="$(fan_conf_get high_temp "$FAN_CONF")"
  fan_band="${fan_low}/${fan_high}"
  fan_default_band="${FAN_LOW_DEFAULT}/${FAN_HIGH_DEFAULT}"
  # "Up to date" means the whole shipped config, not just the band: a 60/90
  # file with speed_curve=linear or always_full_speed=true behaves nothing
  # like the default.
  fan_curve="$(fan_conf_get speed_curve       "$FAN_CONF")"
  fan_afs="$(fan_conf_get always_full_speed "$FAN_CONF")"
  fan_extra_diff=()
  [[ "$fan_curve" == "$FAN_CURVE_DEFAULT" ]] || \
    fan_extra_diff+=("speed_curve=${fan_curve:-<unset>} (default ${FAN_CURVE_DEFAULT})")
  [[ "$fan_afs" == "$FAN_AFS_DEFAULT" ]] || \
    fan_extra_diff+=("always_full_speed=${fan_afs:-<unset>} (default ${FAN_AFS_DEFAULT})")

  # The daemon looks the section up as "Fan1".  A [fan1] header — which this
  # installer shipped once — matches nothing, so the whole file is ignored and
  # t2fanrd silently runs on its own built-in thresholds instead.
  fan_header_ok=0
  grep -qE '^[[:space:]]*\[Fan1\]' "$FAN_CONF" && fan_header_ok=1

  fan_keys_ok=1
  [[ -n "$fan_low" && -n "$fan_high" ]] || fan_keys_ok=0

  fan_is_legacy=0
  for b in "${FAN_LEGACY_BANDS[@]}"; do
    [[ "$fan_band" == "$b" ]] && fan_is_legacy=1
  done

  if (( FORCE_FAN_CONF )); then
    fan_action="rewrite";  fan_why="--force-fan-conf given"
  elif (( ! fan_header_ok || ! fan_keys_ok )); then
    # Nothing in the file is reaching the daemon, so there is no tuning to lose.
    fan_action="rewrite";  fan_why="file is not readable by t2fanrd (bad [Fan1] header or missing thresholds)"
  elif (( fan_is_legacy )); then
    fan_action="rewrite";  fan_why="stale band $fan_band shipped by an older installer"
  elif [[ "$fan_band" != "$fan_default_band" ]]; then
    fan_action="tuned";    fan_why="thresholds $fan_band differ from the default $fan_default_band"
  elif (( ${#fan_extra_diff[@]} )); then
    fan_action="tuned";    fan_why="$(IFS=,; echo "${fan_extra_diff[*]}" | sed 's/,/, /g')"
  else
    fan_action="keep";     fan_why="already at the shipped default ($fan_band, $FAN_CURVE_DEFAULT)"
  fi

  case "$fan_action" in
    rewrite)
      if (( DRY_RUN )); then
        say "Would rewrite $FAN_CONF to ${fan_default_band}: $fan_why"
      else
        backup "$FAN_CONF"
        write_fan_conf "$FAN_CONF"
        warn "Rewrote $FAN_CONF to ${fan_default_band} — $fan_why"
      fi
      ;;
    keep)
      say "Fan daemon config up to date: $fan_why"
      ;;
    tuned)
      warn "Keeping hand-tuned $FAN_CONF — $fan_why"
      warn "  Re-run with --force-fan-conf to reset it to the shipped default."
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 7) Enable services
# ---------------------------------------------------------------------------
if ! (( DRY_RUN )); then systemctl daemon-reload; fi
enable_service "amdgpu-warmfix.service"
# Enabled on every kernel: on one with macsmc_acpi both skip themselves at
# start (ExecCondition=), and the same install still serves an older kernel
# left in the boot menu.
enable_service "t2fanrd.service"
enable_service "t2fanrd-resume.service"
enable_service "applesmc-late.service"
if modinfo -n macsmc_acpi &>/dev/null; then
  say "Fan: $(uname -r) drives the SMC with macsmc — the SMC's own curve runs the fan;"
  say "  t2fanrd and applesmc-late skip themselves on this kernel"
fi

# t2fanrd reads /etc/t2fand.conf and its unit file only at start, so a running
# daemon keeps the old band and the old ExecStartPre until it restarts — a
# reinstall that "rewrote" the config would otherwise change nothing until the
# next boot.  try-restart: a daemon the user stopped on purpose stays stopped.
if (( DRY_RUN )); then
  say "Would restart t2fanrd.service if running"
elif systemctl is-active --quiet t2fanrd.service; then
  # Not fatal: a daemon that fails to come back must not abort the install
  # before the display-manager drop-in and the GRUB steps below.
  if systemctl try-restart t2fanrd.service; then
    say "Restarted t2fanrd.service — new fan config and unit are live"
  else
    warn "t2fanrd.service failed to restart — check: journalctl -u t2fanrd -b"
  fi
fi

# ---------------------------------------------------------------------------
# 8) Display manager drop-in (DM starts only after warmfix completes)
# ---------------------------------------------------------------------------
dm_unit="${UNIT_DIR}/display-manager.service"
if [[ -L "$dm_unit" ]]; then
  drop_dir="${UNIT_DIR}/$(basename "$(realpath "$dm_unit")").d"
else
  drop_dir="${UNIT_DIR}/display-manager.service.d"
fi
gen="$(mktemp)"
cat > "$gen" <<'EOF'
[Unit]
After=amdgpu-warmfix.service
Wants=amdgpu-warmfix.service
EOF
install_file "$gen" "${drop_dir}/10-amdgpu-warmfix.conf"
rm -f -- "$gen"
(( DRY_RUN )) || systemctl daemon-reload

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
say "✅ Installation complete."
# WirePlumber reads its config when the user's session starts, not at boot.
if (( t2_wp_changed && ! DRY_RUN )); then
  say "Speakers and microphone: log out and back in, or run as your user:"
  say "  systemctl --user restart wireplumber"
fi
if [[ -n "${changed[$SW_CURSOR_CONF]:-}" ]] && (( ! DRY_RUN )); then
  say "Cursor: takes effect at the next login (log out and back in)"
fi


# cmdline_ok STRING — every REQUIRED_PARAMS word present, amdgpu not disabled
cmdline_ok() {
  local p
  for p in "${REQUIRED_PARAMS[@]}"; do has_word "$p" "$1" || return 1; done
  ! has_word nomodeset "$1"
}

# mtime PATH — modification time in epoch seconds, 0 when PATH is missing.
# A file a dry run would install counts as changed now.
mtime() {
  if [[ -n "${pending[$1]:-}" ]]; then echo "$EPOCHSECONDS"; return; fi
  stat -c %Y -- "$1" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Work out which follow-up steps are still outstanding.  Each check is one the
# printed command satisfies, so after doing the steps (and rebooting) a re-run
# prints no "Action required" block at all.
# ---------------------------------------------------------------------------

# --- a) /etc/default/grub ---------------------------------------------------
grub_missing=0 initrd_edit=0 cmdline_edit=0 had_nomodeset=0
cur_initrd="" merged=() missing=()
if [[ ! -f "$GRUB_FILE" ]]; then
  grub_missing=1
else
  cur_initrd="$(grub_var GRUB_EARLY_INITRD_LINUX_CUSTOM)"
  [[ "$cur_initrd" == *acpi_override.img* ]] || initrd_edit=1

  cur_cmdline="$(grub_var GRUB_CMDLINE_LINUX)"
  # read -ra, not an unquoted expansion: with nullglob set, a word containing
  # * ? or [ that matches no file would silently vanish from the line.
  read -ra cmdline_words <<<"$cur_cmdline"
  for w in "${cmdline_words[@]}"; do
    # nomodeset keeps amdgpu from probing.  amdgpu.modeset=0 does not: on
    # current kernels the parameter only overrides nomodeset (1 = enable,
    # -1 = auto), so it is left alone.
    if [[ "$w" == nomodeset ]]; then
      had_nomodeset=1          # drop it: amdgpu would not probe the GPU
      continue
    fi
    merged+=("$w")
  done
  for p in "${REQUIRED_PARAMS[@]}"; do
    has_word "$p" "${merged[*]}" || { missing+=("$p"); merged+=("$p"); }
  done
  if (( ${#missing[@]} || had_nomodeset )); then cmdline_edit=1; fi
fi

# --- b) what GRUB actually boots ---------------------------------------------
# With BLS (GRUB_ENABLE_BLSCFG=true, the Fedora default) the kernel cmdline
# lives in each /boot/loader/entries/*.conf, and a plain grub2-mkconfig does
# not touch those: the new GRUB_CMDLINE_LINUX would reach no kernel at all.
# grub2-mkconfig --update-bls-cmdline (Fedora 39+) rewrites the entries too;
# otherwise grubby does.  Fedora's 10_linux puts GRUB_EARLY_INITRD_LINUX_CUSTOM
# into grubenv as early_initrd — the BLS entries never name it.
bls=0 bls_update=0
generated_ok=1 entries_ok=1 entries_seen=0 entries_nomodeset=0

note_entry() {
  entries_seen=$((entries_seen + 1))
  cmdline_ok "$1" || entries_ok=0
  if has_word nomodeset "$1"; then
    entries_nomodeset=1
  fi
}

# grubenv, /boot/loader/entries and `grubby --info` are root-only on Fedora.  A
# non-root --dry-run cannot see them, and must not report them as wrong.
boot_unverified=0
(( EUID == 0 )) || boot_unverified=1

if (( ! grub_missing && ! boot_unverified )); then
  grub_bls && bls=1
  if (( bls )); then
    [[ "$(grub2-mkconfig --help 2>/dev/null)" == *--update-bls-cmdline* ]] && bls_update=1
    names_acpi_img "$(grubenv_var early_initrd)" || generated_ok=0
  else
    grep -qs 'acpi_override\.img' "$grub_cfg" || generated_ok=0
  fi

  # BLS: grubby, or the entries themselves when grubby is missing.  Non-BLS:
  # this system's own grub.cfg entries only, never os-prober's.
  while IFS= read -r line; do
    note_entry "$line"
  done < <(boot_entry_args)
  # Nothing readable is nothing verified.
  (( entries_seen )) || entries_ok=0
fi

need_mkconfig=0 need_grubby=0
if (( ! grub_missing )); then
  if (( initrd_edit || cmdline_edit || ! generated_ok )); then need_mkconfig=1; fi
  if (( ! entries_ok )); then
    if (( bls && ! bls_update )); then need_grubby=1; else need_mkconfig=1; fi
  fi
fi
mkconfig_cmd="sudo grub2-mkconfig -o ${grub_cfg}"
(( bls_update )) && mkconfig_cmd+=" --update-bls-cmdline"

# --- c) initramfs -------------------------------------------------------------
# dracut embeds these files; an image older than the newest of them predates
# the current config.  Rescue and kdump images have no /lib/modules/<name>.
initramfs_inputs=(
  "${DRACUT_DIR}/10-amdgpu-warmfix.conf"
  "${DRACUT_DIR}/20-amdgpu-t2-cmdline.conf"
  /etc/modprobe.d/amdgpu.conf
  /etc/modprobe.d/t2-wifi-off.conf
  "$NAVI10_IMAC_CONF"
)
newest_input=0
for f in "${initramfs_inputs[@]}"; do
  m="$(mtime "$f")"
  if (( m > newest_input )); then newest_input=$m; fi
done
# A deleted input moves no mtime (the --disable-wifi files, say), so look for
# it inside the image instead.  lsinitrd needs root to read the image.
missing_inputs=()
for f in "${initramfs_inputs[@]}"; do
  [[ -e "$f" || -n "${pending[$f]:-}" ]] || missing_inputs+=("${f#/}")
done
in_initramfs() {  # in_initramfs IMAGE PATH — PATH (no leading /) is in IMAGE
  [[ -n "$(lsinitrd -f "$2" "$1" 2>/dev/null)" ]]
}
stale_kvers=()
for img in /boot/initramfs-*.img; do
  kver="${img#/boot/initramfs-}"; kver="${kver%.img}"
  [[ -d "/lib/modules/${kver}" ]] || continue
  if (( $(mtime "$img") < newest_input )); then stale_kvers+=("$kver"); continue; fi
  if (( EUID == 0 )) && command -v lsinitrd &>/dev/null; then
    for f in "${missing_inputs[@]}"; do
      if in_initramfs "$img" "$f"; then stale_kvers+=("$kver"); break; fi
    done
  fi
done

# --- d) reboot ------------------------------------------------------------------
# Every file here is read only at boot.  install_file leaves identical files
# untouched, so an mtime after this boot means a change the system has not
# booted with yet — from this run or an earlier one.
boot_time="$(awk '/^btime/ {print $2}' /proc/stat)"
reboot_why=()
for f in "$ACPI_IMG" \
         "${BIN_DIR}/amdgpu-pci-reset-load.sh" \
         "${UNIT_DIR}/amdgpu-warmfix.service" \
         "${drop_dir}/10-amdgpu-warmfix.conf" \
         /etc/udev/rules.d/99-amdgpu-t2.rules \
         /etc/udev/rules.d/99-t2-usb.rules \
         /etc/udev/rules.d/99-t2-wifi-off.rules \
         "$APPLESMC_CONF" \
         "${initramfs_inputs[@]}"; do
  if (( $(mtime "$f") > boot_time )); then reboot_why+=("$f (changed since boot)"); fi
done
if ! cmdline_ok "$(cat /proc/cmdline)"; then
  reboot_why+=("kernel parameters: /proc/cmdline lacks ${REQUIRED_PARAMS[*]} or has nomodeset")
fi
# The journal, not dmesg: the printk buffer wraps.  Judge only a journal that
# still starts at the boot's first kernel line; journald may have vacuumed it.
# Loaded means the table header with its address ("ACPI: SSDT 0x…"); the
# "table found in initrd" line names the file even when the load fails.
kmsg="$(journalctl -k -b -q -o cat --no-pager 2>/dev/null)" || kmsg=""
if [[ -f "$ACPI_IMG" && "$kmsg" == "Linux version "* ]]; then
  img_tables="$(cpio -it --quiet < "$ACPI_IMG" 2>/dev/null)" || img_tables=""
  if [[ "$img_tables" == *GFXALT* ]] \
     && ! grep -qE '^ACPI: SSDT 0x[0-9A-Fa-f]+ .* GFXALT ' <<<"$kmsg"; then
    reboot_why+=("GFXALT SSDT: not loaded in this boot")
  fi
  if [[ "$img_tables" == *TbtOnPCH* ]] \
     && ! grep -qE '^ACPI: Table Upgrade: override \[SSDT-APPLE *-TbtOnPCH\]' <<<"$kmsg"; then
    reboot_why+=("TbtOnPCH resume patch: not loaded in this boot")
  fi
fi

pending_setup=$(( grub_missing || initrd_edit || cmdline_edit || need_mkconfig \
                  || need_grubby || ${#stale_kvers[@]} ))

unverified_note="Not run as root: GRUB config and boot entries were not checked."
if (( ! pending_setup && ${#reboot_why[@]} == 0 )); then
  if (( boot_unverified )); then
    say "No action required in what could be checked — initramfs and the running boot are up to date."
    warn "$unverified_note"
  else
    say "No action required — bootloader, initramfs and the running boot are up to date."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Print only the outstanding steps, numbered in order
# ---------------------------------------------------------------------------
n=0
echo
echo "====== Action required ======"
(( DRY_RUN )) && echo "(dry run: counts the files listed above as \"Would install\" as already changed)"
(( boot_unverified )) && warn "$unverified_note"
echo

if (( grub_missing )); then
  n=$((n + 1))
  echo "${n}. Bootloader configuration"
  warn "${GRUB_FILE} not found — set these by hand in your bootloader config:"
  echo "    GRUB_EARLY_INITRD_LINUX_CUSTOM=\"acpi_override.img\""
  echo "    GRUB_CMDLINE_LINUX=\"${REQUIRED_PARAMS[*]}\""
  echo
fi

if (( initrd_edit || cmdline_edit )); then
  n=$((n + 1))
  echo "${n}. Edit ${GRUB_FILE}:"
  echo
  if (( initrd_edit )); then
    echo "   GRUB_EARLY_INITRD_LINUX_CUSTOM — loads the ACPI override image"
    if [[ -n "$cur_initrd" ]]; then
      echo "      Set to \"${cur_initrd}\" — append acpi_override.img, so the line becomes:"
      echo
      echo "        GRUB_EARLY_INITRD_LINUX_CUSTOM=\"${cur_initrd} acpi_override.img\""
    else
      echo "      Not set. Add this line:"
      echo
      echo "        GRUB_EARLY_INITRD_LINUX_CUSTOM=\"acpi_override.img\""
    fi
    echo
  fi
  if (( cmdline_edit )); then
    echo "   GRUB_CMDLINE_LINUX — kernel parameters"
    (( ${#missing[@]} )) && \
      echo "      Missing ${#missing[@]} parameter(s): ${missing[*]}"
    (( had_nomodeset )) && \
      warn "     nomodeset is set — it keeps amdgpu from probing the GPU; removing it below"
    echo "      Your existing parameters are kept. Replace the whole line with:"
    echo
    echo "        GRUB_CMDLINE_LINUX=\"${merged[*]}\""
    echo
  fi
fi

if (( need_mkconfig )); then
  n=$((n + 1))
  echo "${n}. Regenerate the GRUB config (${boot_mode}):"
  echo
  echo "     ${mkconfig_cmd}"
  echo
fi

if (( need_grubby )); then
  n=$((n + 1))
  echo "${n}. Apply the kernel parameters to every installed kernel — BLS entries"
  echo "   carry their own cmdline and this grub2-mkconfig cannot update them:"
  echo
  if command -v grubby &>/dev/null; then
    echo "     sudo grubby --update-kernel=ALL --args=\"${REQUIRED_PARAMS[*]}\""
    (( entries_nomodeset )) && \
      echo "     sudo grubby --update-kernel=ALL --remove-args=nomodeset"
  else
    echo "     grubby is not installed.  Install it (sudo dnf install grubby) and re-run"
    echo "     this installer, or add ${REQUIRED_PARAMS[*]} to the options"
    echo "     line of each /boot/loader/entries/*.conf by hand."
    (( entries_nomodeset )) && \
      echo "     Remove nomodeset from those lines too."
  fi
  echo
fi

if (( ${#stale_kvers[@]} )); then
  n=$((n + 1))
  echo "${n}. Rebuild the initramfs — older than the dracut/modprobe config it embeds:"
  echo
  if (( ${#stale_kvers[@]} > 1 )); then
    echo "     sudo dracut -f --regenerate-all"
  else
    echo "     sudo dracut -f --kver ${stale_kvers[0]}"
  fi
  echo
fi

n=$((n + 1))
echo "${n}. Reboot."
if (( ${#reboot_why[@]} )); then
  echo "   Not yet active in the running boot:"
  printf '     %s\n' "${reboot_why[@]}"
fi

cat <<'EOF'

======================================================================

EOF
