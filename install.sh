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
STATE_DIR="/var/lib/t2-pci-amdgpu"
TBT_BIOS_FILE="${STATE_DIR}/TbtOnPCH.bios"

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
    cp "${SRC_DIR}/GFXALT-multi.aml" "$acpi_dir/"
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
set -Eeuo pipefail
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
if (( DISABLE_WIFI )); then
  install_file "${SRC_DIR}/99-t2-wifi-off.rules"    "/etc/udev/rules.d/99-t2-wifi-off.rules"
  install_file "${SRC_DIR}/t2-wifi-off.conf"        "/etc/modprobe.d/t2-wifi-off.conf"
elif [[ -f /etc/udev/rules.d/99-t2-wifi-off.rules || -f /etc/modprobe.d/t2-wifi-off.conf ]]; then
  say "Keeping the --disable-wifi files — Wi-Fi stays off (delete /etc/udev/rules.d/99-t2-wifi-off.rules"
  say "  and /etc/modprobe.d/t2-wifi-off.conf to bring it back)"
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
enable_service "t2fanrd.service"
enable_service "t2fanrd-resume.service"
enable_service "applesmc-late.service"

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

GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"   # overridable for testing

# Since Fedora 34 the EFI partition holds only a stub grub.cfg that hands off
# to /boot/grub2/grub.cfg (it calls `configfile`).  Pointing grub2-mkconfig at
# the stub overwrites it with a full config that kernel updates never refresh.
# Write the EFI path only on a system where it really is the config.
grub_cfg="/boot/grub2/grub.cfg"
if [[ -d /sys/firmware/efi ]]; then
  boot_mode="EFI"
  efi_cfg="/boot/efi/EFI/fedora/grub.cfg"
  if [[ -r "$efi_cfg" ]] && ! grep -q 'configfile' "$efi_cfg" 2>/dev/null; then
    grub_cfg="$efi_cfg"
  fi
else
  boot_mode="Legacy BIOS"
fi
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
  # read -ra, not an unquoted expansion: with nullglob set, a word containing
  # * ? or [ that matches no file would silently vanish from the line.
  read -ra cmdline_words <<<"$cur_cmdline"
  for w in "${cmdline_words[@]}"; do
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

# With BLS (GRUB_ENABLE_BLSCFG=true, the Fedora default) the kernel cmdline
# lives in each /boot/loader/entries/*.conf, and a plain grub2-mkconfig does
# not touch those: the new GRUB_CMDLINE_LINUX would reach no kernel at all.
# grub2-mkconfig --update-bls-cmdline (Fedora 39+) rewrites the entries too.
mkconfig_cmd="sudo grub2-mkconfig -o ${grub_cfg}"
bls_note=""
if [[ "$(grub_var GRUB_ENABLE_BLSCFG)" == "true" ]]; then
  if grub2-mkconfig --help 2>/dev/null | grep -q -- '--update-bls-cmdline'; then
    mkconfig_cmd+=" --update-bls-cmdline"
  else
    bls_note="     BLS entries carry their own cmdline and this grub2-mkconfig cannot
     update them; apply the parameters to every installed kernel with:

       sudo grubby --update-kernel=ALL --args=\"${REQUIRED_PARAMS[*]}\"
"
    (( had_nomodeset )) && bls_note+="       sudo grubby --update-kernel=ALL --remove-args=\"nomodeset amdgpu.modeset=0\"
"
  fi
fi

cat <<EOF

2. Regenerate the GRUB config and the initramfs:

     ${mkconfig_cmd}
     sudo dracut -f
${bls_note:+
${bls_note}}
3. Reboot.

======================================================================

EOF
