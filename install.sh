#!/usr/bin/env bash
# install.sh — AMDGPU warmfix installer for Apple T2 iMac Intel
#
# Installs:
#   - ACPI override image from GFXALT-multi.aml → /boot/acpi_override.img
#   - systemd service units          → /etc/systemd/system/
#   - GPU PCI reset script           → /usr/local/bin/ (generated from template)
#   - Helper scripts + t2fanrd       → /usr/local/bin/
#   - modprobe.d, udev, dracut files → respective system dirs
#   - Display manager drop-in        → warmfix runs before DM at boot
#
# Usage: sudo ./install.sh [--dry-run] [--force-fan-conf]
#
#   --dry-run          Show what would be installed without making changes
#   --force-fan-conf   Overwrite /etc/t2fand.conf with the shipped default even
#                      if its thresholds look hand-tuned
#
set -Eeuo pipefail
shopt -s nullglob

DRY_RUN=0
FORCE_FAN_CONF=0
while (( $# )); do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --force-fan-conf) FORCE_FAN_CONF=1 ;;
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

# install_file SRC DST [MODE]  — backup DST if present, then install SRC → DST
install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ ! -f "$src" ]]; then
    warn "Not found, skipping: $src"
    return
  fi
  if (( DRY_RUN )); then say "Would install: $src → $dst (mode $mode)"; return 0; fi
  backup "$dst"
  install -Dm"$mode" "$src" "$dst"
  say "Installed: $dst"
}

require_root() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || { err "Run with sudo/root."; exit 1; }
}

check_deps() {
  local missing=()
  for cmd in cpio gzip systemctl modprobe udevadm realpath install; do
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
  if [[ -f "${UNIT_DIR}/${unit}" ]]; then
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

require_root
check_deps
(( DRY_RUN )) && say "=== DRY RUN — no changes will be made ==="
say "AMDGPU warmfix installation — source: ${SRC_DIR}"

# ---------------------------------------------------------------------------
# 1) ACPI override image
# ---------------------------------------------------------------------------
acpi_needs_update=1
if [[ -f "$ACPI_IMG" && -f "${SRC_DIR}/GFXALT-multi.aml" ]]; then
  # Rebuild only if the .aml source has changed since the image was built
  if [[ "${SRC_DIR}/GFXALT-multi.aml" -ot "$ACPI_IMG" ]]; then
    acpi_needs_update=0
    say "ACPI override is up to date: $ACPI_IMG — skipping"
  else
    say "ACPI source is newer than image — rebuilding"
  fi
elif [[ -f "$ACPI_IMG" ]]; then
  acpi_needs_update=0
  say "ACPI override already present: $ACPI_IMG — skipping"
fi
if (( acpi_needs_update )) && [[ -f "${SRC_DIR}/GFXALT-multi.aml" ]]; then
  if (( DRY_RUN )); then
    say "Would build ACPI override image: $ACPI_IMG"
  else
    say "Building ACPI override image: $ACPI_IMG"
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/kernel/firmware/acpi"
    cp "${SRC_DIR}/GFXALT-multi.aml" "$tmpdir/kernel/firmware/acpi/"
    ( cd "$tmpdir" && find kernel | cpio -H newc --quiet -o | gzip ) > "$ACPI_IMG"
    rm -rf "$tmpdir"
    say "Installed: $ACPI_IMG"
  fi
elif (( acpi_needs_update )); then
  warn "GFXALT-multi.aml not found — ACPI override skipped (required for GPU fix)"
fi

# ---------------------------------------------------------------------------
# 2) Service units → /etc/systemd/system/
# ---------------------------------------------------------------------------
say "Installing service units"
for f in "${SRC_DIR}"/*.service; do
  install_file "$f" "${UNIT_DIR}/$(basename "$f")"
done

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
  if (( DRY_RUN )); then
    say "Would generate: $target (slot: ${slot})"
  else
    backup "$target"
    {
      cat <<'HDR'
#!/usr/bin/env bash
# amdgpu-pci-reset-load.sh — generated by install.sh; do not edit manually
set -euo pipefail
log(){ echo "[amdgpu-warmfix] $*"; }
HDR
      sed "s/ADDR/${slot}/g" "$template"
    } > "$target"
    chmod 0755 "$target"
    say "Installed: $target (slot: ${slot})"
  fi
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

for bin in t2fanrd; do
  install_file "${SRC_DIR}/${bin}" "${BIN_DIR}/${bin}" 0755
done

# ---------------------------------------------------------------------------
# 5) System config files
# ---------------------------------------------------------------------------
if ! (( DRY_RUN )); then mkdir -p /etc/modprobe.d /etc/udev/rules.d "$DRACUT_DIR"; fi
install_file "${SRC_DIR}/amdgpu.conf"               "/etc/modprobe.d/amdgpu.conf"
install_file "${SRC_DIR}/99-amdgpu-t2.rules"        "/etc/udev/rules.d/99-amdgpu-t2.rules"
install_file "${SRC_DIR}/99-t2-usb.rules"           "/etc/udev/rules.d/99-t2-usb.rules"
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
  elif [[ "$fan_band" == "$fan_default_band" ]]; then
    fan_action="keep";     fan_why="already at the shipped default ($fan_band)"
  else
    fan_action="tuned";    fan_why="thresholds $fan_band differ from the default $fan_default_band"
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
enable_service "t2fanrd.service"
enable_service "t2fanrd-resume.service"
enable_service "applesmc-late.service"

# ---------------------------------------------------------------------------
# 8) Display manager drop-in (DM starts only after warmfix completes)
# ---------------------------------------------------------------------------
dm_unit="${UNIT_DIR}/display-manager.service"
if [[ -L "$dm_unit" ]]; then
  drop_dir="${UNIT_DIR}/$(basename "$(realpath "$dm_unit")").d"
else
  drop_dir="${UNIT_DIR}/display-manager.service.d"
fi
if (( DRY_RUN )); then
  say "Would install DM drop-in: ${drop_dir}/10-amdgpu-warmfix.conf"
else
  mkdir -p "$drop_dir"
  backup "${drop_dir}/10-amdgpu-warmfix.conf"
  cat > "${drop_dir}/10-amdgpu-warmfix.conf" <<'EOF'
[Unit]
After=amdgpu-warmfix.service
Wants=amdgpu-warmfix.service
EOF
  chmod 0644 "${drop_dir}/10-amdgpu-warmfix.conf"
  systemctl daemon-reload
  say "Drop-in installed: ${drop_dir}/10-amdgpu-warmfix.conf"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
say "✅ Installation complete."

if [[ -d /sys/firmware/efi ]]; then
  grub_cfg="/boot/efi/EFI/fedora/grub.cfg"
  boot_mode="EFI"
else
  grub_cfg="/boot/grub2/grub.cfg"
  boot_mode="Legacy BIOS"
fi

GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"   # overridable for testing
REQUIRED_PARAMS=(pci=noaer pcie_aspm=off amdgpu.aspm=0 amdgpu.runpm=0)

# grub_var NAME — value of the last NAME= assignment in $GRUB_FILE, unquoted
grub_var() {
  local line
  [[ -f "$GRUB_FILE" ]] || return 0
  line="$(grep -E "^[[:space:]]*$1=" "$GRUB_FILE" 2>/dev/null | tail -n1)" || true
  [[ -n "$line" ]] || return 0
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

echo
echo "====== Action required: ${GRUB_FILE}  (detected: ${boot_mode}) ======"
echo

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "1. Bootloader configuration"
  warn "${GRUB_FILE} not found — set these by hand in your bootloader config:"
  echo "    GRUB_EARLY_INITRD_LINUX_CUSTOM=\"acpi_override.img\""
  echo "    GRUB_CMDLINE_LINUX=\"${REQUIRED_PARAMS[*]}\""
else
  echo "1. Edit ${GRUB_FILE} — two variables, described one at a time."
  echo

  # --- a) early initrd -------------------------------------------------------
  cur_initrd="$(grub_var GRUB_EARLY_INITRD_LINUX_CUSTOM)"
  echo "   a) GRUB_EARLY_INITRD_LINUX_CUSTOM — loads the ACPI override image"
  if [[ "$cur_initrd" == *acpi_override.img* ]]; then
    echo "      Already correct, nothing to do:"
    echo "        GRUB_EARLY_INITRD_LINUX_CUSTOM=\"${cur_initrd}\""
  elif [[ -n "$cur_initrd" ]]; then
    echo "      Set to \"${cur_initrd}\" — append acpi_override.img, so the line becomes:"
    echo
    echo "        GRUB_EARLY_INITRD_LINUX_CUSTOM=\"${cur_initrd} acpi_override.img\""
  else
    echo "      Not set. Add this line:"
    echo
    echo "        GRUB_EARLY_INITRD_LINUX_CUSTOM=\"acpi_override.img\""
  fi
  echo

  # --- b) kernel cmdline -----------------------------------------------------
  cur_cmdline="$(grub_var GRUB_CMDLINE_LINUX)"
  merged=()
  had_nomodeset=0
  for w in $cur_cmdline; do
    if [[ "$w" == nomodeset || "$w" == amdgpu.modeset=0 ]]; then
      had_nomodeset=1          # drop it: it disables the amdgpu driver entirely
      continue
    fi
    merged+=("$w")
  done
  missing=()
  for p in "${REQUIRED_PARAMS[@]}"; do
    found=0
    for w in "${merged[@]}"; do [[ "$w" == "$p" ]] && { found=1; break; }; done
    (( found )) || { missing+=("$p"); merged+=("$p"); }
  done

  echo "   b) GRUB_CMDLINE_LINUX — kernel parameters"
  if (( ${#missing[@]} == 0 && had_nomodeset == 0 )); then
    echo "      Already correct, nothing to do."
  else
    (( ${#missing[@]} )) && \
      echo "      Missing ${#missing[@]} parameter(s): ${missing[*]}"
    (( had_nomodeset )) && \
      warn "     nomodeset/amdgpu.modeset=0 is set — it disables amdgpu; removing it below"
    echo "      Your existing parameters are kept. Replace the whole line with:"
    echo
    echo "        GRUB_CMDLINE_LINUX=\"${merged[*]}\""
  fi
fi

cat <<EOF

2. Regenerate the GRUB config and the initramfs:

     sudo grub2-mkconfig -o ${grub_cfg}
     sudo dracut -f

3. Reboot.

======================================================================

EOF
