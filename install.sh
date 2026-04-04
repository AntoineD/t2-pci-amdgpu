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
# Usage: sudo ./install.sh
#
set -Eeuo pipefail
shopt -s nullglob

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
  backup "$dst"
  install -Dm"$mode" "$src" "$dst"
  say "Installed: $dst"
}

require_root() {
  [[ $EUID -eq 0 ]] || { err "Run with sudo/root."; exit 1; }
}

check_deps() {
  local missing=()
  for cmd in cpio gzip systemctl modprobe udevadm realpath install; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || { err "Missing tools: ${missing[*]}"; exit 1; }
}

enable_service() {
  local unit="$1"
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
say "AMDGPU warmfix installation — source: ${SRC_DIR}"

# ---------------------------------------------------------------------------
# 1) ACPI override image
# ---------------------------------------------------------------------------
if [[ -f "$ACPI_IMG" ]]; then
  say "ACPI override already present: $ACPI_IMG — skipping"
elif [[ -f "${SRC_DIR}/GFXALT-multi.aml" ]]; then
  say "Building ACPI override image: $ACPI_IMG"
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/kernel/firmware/acpi"
  cp "${SRC_DIR}/GFXALT-multi.aml" "$tmpdir/kernel/firmware/acpi/"
  ( cd "$tmpdir" && find kernel | cpio -H newc --quiet -o | gzip ) > "$ACPI_IMG"
  rm -rf "$tmpdir"
  say "Installed: $ACPI_IMG"
else
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
else
  warn "Template not found: $template — skipping GPU reset script"
fi

# ---------------------------------------------------------------------------
# 4) Scripts and binaries → /usr/local/bin/
# ---------------------------------------------------------------------------
say "Installing scripts to ${BIN_DIR}"
for f in "${SRC_DIR}"/*.sh; do
  [[ "$(basename "$f")" == "install.sh" ]] && continue
  install_file "$f" "${BIN_DIR}/$(basename "$f")" 0755
done

for bin in t2fanrd; do
  install_file "${SRC_DIR}/${bin}" "${BIN_DIR}/${bin}" 0755
done

# ---------------------------------------------------------------------------
# 5) System config files
# ---------------------------------------------------------------------------
mkdir -p /etc/modprobe.d /etc/udev/rules.d "$DRACUT_DIR"
install_file "${SRC_DIR}/amdgpu.conf"               "/etc/modprobe.d/amdgpu.conf"
install_file "${SRC_DIR}/99-amdgpu-t2.rules"        "/etc/udev/rules.d/99-amdgpu-t2.rules"
install_file "${SRC_DIR}/10-amdgpu-warmfix.conf"    "${DRACUT_DIR}/10-amdgpu-warmfix.conf"
install_file "${SRC_DIR}/20-amdgpu-t2-cmdline.conf" "${DRACUT_DIR}/20-amdgpu-t2-cmdline.conf"
udevadm control --reload-rules
say "udev rules reloaded"

# ---------------------------------------------------------------------------
# 6) Default t2fanrd config (skipped if already present — user may have tuned it)
# ---------------------------------------------------------------------------
if [[ -f /etc/t2fanrd.conf ]]; then
  say "t2fanrd config exists — skipping (delete to regenerate)"
else
  cat > /etc/t2fanrd.conf <<'EOF'
# /etc/t2fanrd.conf — T2 fan daemon configuration
# Adjust low_temp/high_temp (°C) to suit your hardware.
# speed_curve: linear | exponential | logarithmic
# always_full_speed: true | false

[fan1]
low_temp = 55
high_temp = 85
speed_curve = linear
always_full_speed = false
EOF
  chmod 0644 /etc/t2fanrd.conf
  warn "Default /etc/t2fanrd.conf created — review thresholds for your hardware"
fi

# ---------------------------------------------------------------------------
# 7) Enable services
# ---------------------------------------------------------------------------
systemctl daemon-reload
enable_service "amdgpu-warmfix.service"
enable_service "t2fanrd.service"
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

cat <<EOF

====== Action required: /etc/default/grub  (detected: ${boot_mode}) ======

  GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.img"
  GRUB_CMDLINE_LINUX="pci=noaer pcie_aspm=off amdgpu.aspm=0 amdgpu.runpm=0"
  (remove 'nomodeset' if present)

Then regenerate GRUB and initramfs:
  sudo grub2-mkconfig -o ${grub_cfg}
  sudo dracut -f

Reboot when ready.
======================================================================

EOF
