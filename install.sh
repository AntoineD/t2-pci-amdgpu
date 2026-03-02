#!/usr/bin/env bash
# install.sh — Installer for AMDGPU warmfix (iMac Intel)
#
# Summary:
#   - Require root
#   - (Optional) Build /boot/acpi_override.img from GFXALT-multi.aml if missing
#   - Install *.service units to /etc/systemd/system (with backups)
#   - Generate /usr/local/bin/amdgpu-pci-reset-load.sh from "amdgpu-reset-pci-template" (ADDR replacement)
#   - Install executables from this folder to /usr/local/bin (scripts *.sh and binaries like t2fanrd), excluding the installer, services, and the template
#   - Create a symlink-aware drop-in so the display manager starts AFTER warmfix
#
# Usage:
#   sudo ./install.sh 
#
set -euo pipefail

# --- Debug helpers -----------------------------------------------------------
# Enable verbose tracing & failure trap with DEBUG=1
if [[ "${DEBUG:-0}" = "1" ]]; then
  PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
fi
set -o errtrace
trap 'ec=$?; echo "[✗] FAILED at ${BASH_SOURCE##*/}:${LINENO} → ${BASH_COMMAND} (exit $ec)"; exit $ec' ERR

say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; }
ask_yn(){ local p="${1:-Continue?} [Y/n] "; read -r -p "$p" a||true; case "${a:-Y}" in [Yy]*|"") return 0;; *) return 1;; esac; }
backup(){ [[ -e "$1" ]] || return 0; local ts; ts="$(date +%Y%m%d-%H%M%S)"; cp -a -- "$1" "$1.bak.$ts"; say "Backup created: $1.bak.$ts"; }

require_root(){ [[ $EUID -eq 0 ]] || { err "Run this script with sudo/root."; exit 1; }; }

WITH_DRACUT=0
for arg in "$@"; do
  case "$arg" in
    --with-dracut) WITH_DRACUT=1 ;;
    *) err "Unknown argument: $arg" ; exit 1 ;;
  esac
done

# --- Paths -------------------------------------------------------------------
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
DRACUT_DIR="/etc/dracut.conf.d"
DRACUT_CONF="${DRACUT_DIR}/10-amdgpu-warmfix.conf"
ACPI_IMG="/boot/acpi_override.img"
ACPI_SRC="${SRC_DIR}/GFXALT-multi.aml"

require_root
say "Starting amdgpu warmfix installation"
say "Source directory: ${SRC_DIR}"
ls -al "${SRC_DIR}" || true

# --- 0) ACPI override image (optional) ---------------------------------------
if [[ -f "$ACPI_IMG" ]]; then
  say "acpi_override.img already present in /boot — skipping creation."
elif [[ -f "$ACPI_SRC" ]]; then
  say "Creating /boot/acpi_override.img from GFXALT-multi.aml"
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/kernel/firmware/acpi"
  cp "$ACPI_SRC" "$tmpdir/kernel/firmware/acpi/"
  ( cd "$tmpdir" && find kernel | cpio -H newc --quiet -o | gzip > acpi_override.img )
  cp "$tmpdir/acpi_override.img" "$ACPI_IMG"
  rm -rf "$tmpdir"
  say "Installed ACPI override image: $ACPI_IMG"
else
  warn "No ACPI override created (missing $ACPI_SRC) — this is optional."
fi

# --- 1) Install *.service units ----------------------------------------------
shopt -s nullglob
say "Installing systemd units"
mapfile -t SERVICES < <(compgen -G "${SRC_DIR}/*.service" || true)
say "Found ${#SERVICES[@]} service file(s): ${SERVICES[*]:-<none>}"
for f in "${SERVICES[@]}"; do
  dst="${UNIT_DIR}/$(basename "$f")"
  backup "$dst"
  install -Dm0644 "$f" "$dst"
  say "Installed service: $dst"
done
(( ${#SERVICES[@]} )) || warn "No *.service files found here (ok if already installed)."

# --- 2) Generate GPU reset script from template ------------------------------
TEMPLATE="${SRC_DIR}/amdgpu-reset-pci-template"
TARGET="${BIN_DIR}/amdgpu-pci-reset-load.sh"

if [[ -f "$TEMPLATE" ]]; then
  say "Generating amdgpu-pci-reset-load.sh from template (ADDR replacement)"
  # Prefer lspci for discovery; fallback to sysfs-only if lspci missing.
  gpu_bdf="$(lspci -D -nn 2>/dev/null | awk '/VGA compatible controller/ && /\[1002:/{print $1; exit}')" || true
  if [[ -z "${gpu_bdf:-}" ]]; then
    # sysfs fallback: AMD vendor 0x1002 + VGA class 0x0300*
    gpu_bdf="$(for d in /sys/bus/pci/devices/*; do \
                 [[ -e "$d/vendor" && -e "$d/class" ]] || continue; \
                 read -r ven < "$d/vendor"; read -r cls < "$d/class"; \
                 if [[ "$ven" == "0x1002" && "$cls" == 0x0300* ]]; then basename "$d"; break; fi; \
               done)"
  fi
  if [[ -z "${gpu_bdf:-}" ]]; then
    err "Could not detect AMD VGA device (neither lspci nor sysfs fallback worked)."
    exit 1
  fi
  slot_root="${gpu_bdf%.*}"                # e.g., 0000:03:00
  slot_root="${slot_root#0000:}"           # template keeps the '0000:' prefix literal
  backup "$TARGET"
  {
    cat <<'HDR'
#!/usr/bin/env bash
# amdgpu-pci-reset-load.sh — PCI remove/rescan helper for AMD GPU (audio first)
set -euo pipefail
log(){ echo "[amdgpu-warmfix] $*"; }
HDR
    sed "s/ADDR/${slot_root}/g" "$TEMPLATE"
  } > "$TARGET"
  chmod 0755 "$TARGET"
  say "Installed script: $TARGET (slot root: ${slot_root})"
else
  warn "Template not found: $TEMPLATE — skipping generation of amdgpu-pci-reset-load.sh"
fi


say "Installing scripts (*.sh) to ${BIN_DIR}"
shopt -s nullglob
for f in "${SRC_DIR}"/*.sh; do
  base="$(basename "$f")"
  [[ "$base" == "install.sh" ]] && continue   # don't copy installer
  backup "${BIN_DIR}/${base}"
  install -Dm0755 "$f" "${BIN_DIR}/${base}"
  say "Installed script: ${BIN_DIR}/${base}"
done

# --- Install standalone binaries ---------------------------------------------
for bin in t2fanrd; do
  src="${SRC_DIR}/${bin}"
  if [[ -f "$src" ]]; then
    backup "${BIN_DIR}/${bin}"
    install -Dm0755 "$src" "${BIN_DIR}/${bin}"
    say "Installed binary: ${BIN_DIR}/${bin}"
  else
    warn "Binary not found in source dir: ${bin} — skipping"
  fi
done

# --- 4) systemd: daemon-reload + enable services -----------------------------
say "Reloading systemd units"
systemctl daemon-reload

enable_if_present() {
  local unit="$1"
  if [[ -f "${UNIT_DIR}/${unit}" ]]; then
    systemctl enable "$unit"
    say "Enabled $unit"
  fi
}
enable_if_present "amdgpu-warmfix.service"
enable_if_present "t2fanrd.service"
enable_if_present "applesmc-late.service"

# --- 5) Display manager drop-in (symlink-aware) ------------------------------
say "Configuring display-manager drop-in (symlink-aware)"
dm_unit="/etc/systemd/system/display-manager.service"
if [[ -L "$dm_unit" ]]; then
  real_unit="$(realpath "$dm_unit")"
  real_name="$(basename "$real_unit")"
  drop_dir="/etc/systemd/system/${real_name}.d"
else
  drop_dir="/etc/systemd/system/display-manager.service.d"
fi
mkdir -p "$drop_dir"
drop_file="${drop_dir}/10-amdgpu-warmfix.conf"
backup "$drop_file"
cat > "$drop_file" <<'EOF'
[Unit]
After=amdgpu-warmfix.service
Wants=amdgpu-warmfix.service
EOF
chmod 0644 "$drop_file"
systemctl daemon-reload
say "Drop-in installed: ${drop_file}"

say "✅ Installation finished."
echo ""
echo ""
echo " ============================ /etc/default/grub.cfg ================="
echo "here the recommanded parameter for grub.  Add/Change lines in your /etc/default/grub.cfg"
echo " ============================ /etc/default/grub.cfg ================="
echo "GRUB_EARLY_INITRD_LINUX_CUSTOM=\"acpi_override.img\"             #Required"
echo "GRUB_CMDLINE_LINUX=\"pci=noaer pcie_aspm=off amdgpu.aspm=0\"     #Backup your file, and others else parameters"
echo "                                                               can interfired"
echo ""
echo "regenerate your grub.cfg" 
echo ""
echo "Reboot when you are ready."

