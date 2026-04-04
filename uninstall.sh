#!/usr/bin/env bash
# uninstall.sh — Remove AMDGPU warmfix components installed by install.sh
#
# Usage: sudo ./uninstall.sh [--all]
#
#   --all   Also remove /boot/acpi_override.img and /etc/t2fanrd.conf
#
set -Eeuo pipefail

[[ "${DEBUG:-0}" == "1" ]] && { PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '; set -x; }

say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; }

remove_file() {
  if [[ -e "$1" ]]; then
    rm -f -- "$1"
    say "Removed: $1"
  fi
}

[[ $EUID -eq 0 ]] || { err "Run with sudo/root."; exit 1; }

REMOVE_ALL=0
[[ "${1:-}" == "--all" ]] && REMOVE_ALL=1

say "AMDGPU warmfix uninstallation"

# ---------------------------------------------------------------------------
# 1) Stop and disable services
# ---------------------------------------------------------------------------
for svc in amdgpu-warmfix.service t2fanrd.service applesmc-late.service; do
  if systemctl is-enabled "$svc" &>/dev/null; then
    systemctl disable "$svc"
    say "Disabled: $svc"
  fi
  if systemctl is-active "$svc" &>/dev/null; then
    systemctl stop "$svc"
    say "Stopped: $svc"
  fi
done

# ---------------------------------------------------------------------------
# 2) Remove DM drop-in
# ---------------------------------------------------------------------------
dm_unit="/etc/systemd/system/display-manager.service"
if [[ -L "$dm_unit" ]]; then
  drop_dir="/etc/systemd/system/$(basename "$(realpath "$dm_unit")").d"
else
  drop_dir="/etc/systemd/system/display-manager.service.d"
fi
remove_file "${drop_dir}/10-amdgpu-warmfix.conf"
# Remove the drop-in directory if empty
rmdir -- "$drop_dir" 2>/dev/null && say "Removed empty dir: $drop_dir" || true

# ---------------------------------------------------------------------------
# 3) Remove service units
# ---------------------------------------------------------------------------
for f in amdgpu-warmfix.service t2fanrd.service applesmc-late.service; do
  remove_file "/etc/systemd/system/$f"
done

# ---------------------------------------------------------------------------
# 4) Remove scripts and binaries from /usr/local/bin/
# ---------------------------------------------------------------------------
for f in amdgpu-pci-reset-load.sh amdgpu-check.sh t2-gpu-status.sh t2fanrd; do
  remove_file "/usr/local/bin/$f"
done

# ---------------------------------------------------------------------------
# 5) Remove system config files
# ---------------------------------------------------------------------------
remove_file "/etc/modprobe.d/amdgpu.conf"
remove_file "/etc/udev/rules.d/99-amdgpu-t2.rules"
remove_file "/etc/dracut.conf.d/10-amdgpu-warmfix.conf"
remove_file "/etc/dracut.conf.d/20-amdgpu-t2-cmdline.conf"

# ---------------------------------------------------------------------------
# 6) Optionally remove ACPI image and t2fanrd config
# ---------------------------------------------------------------------------
if (( REMOVE_ALL )); then
  remove_file "/boot/acpi_override.img"
  remove_file "/etc/t2fanrd.conf"
else
  warn "Kept /boot/acpi_override.img and /etc/t2fanrd.conf (use --all to remove)"
fi

# ---------------------------------------------------------------------------
# 7) Reload daemons
# ---------------------------------------------------------------------------
systemctl daemon-reload
udevadm control --reload-rules
say "systemd and udev reloaded"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
say "Uninstallation complete."
cat <<'EOF'

Remember to:
  1. Remove GRUB_EARLY_INITRD_LINUX_CUSTOM and amdgpu/pcie params from /etc/default/grub
  2. Regenerate GRUB config: sudo grub2-mkconfig -o <your grub.cfg>
  3. Rebuild initramfs:      sudo dracut -f

EOF
