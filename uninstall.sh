#!/usr/bin/env bash
# uninstall.sh — Remove AMDGPU warmfix components installed by install.sh
#
# Usage: sudo ./uninstall.sh [--all]
#
#   --all   Also remove /boot/acpi_override.img and /etc/t2fand.conf
#           (plus the legacy /etc/t2fanrd.conf, which t2fanrd never read)
#
set -Eeuo pipefail

[[ "${DEBUG:-0}" == "1" ]] && { PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '; set -x; }

say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; }

remove_file() {
  [[ -e "$1" ]] || return 0
  rm -f -- "$1"
  say "Removed: $1"
}

# offer_restore FILE — find .bak.* backups and let the user pick one to restore
offer_restore() {
  local file="$1"
  local backups=()
  # Collect backups sorted newest-first
  while IFS= read -r -d '' b; do
    backups+=("$b")
  done < <(find "$(dirname "$file")" -maxdepth 1 \
    -name "$(basename "$file").bak.*" -print0 2>/dev/null | sort -z -r)

  (( ${#backups[@]} )) || { remove_file "$file"; return 0; }

  echo
  say "Found ${#backups[@]} backup(s) for $file:"
  local i
  for i in "${!backups[@]}"; do
    # Extract the YYYYMMDD-HHMMSS timestamp from the suffix
    local ts="${backups[$i]##*.bak.}"
    printf "  %d) %s\n" "$((i + 1))" "$ts"
  done
  printf "  0) Do not restore (delete the installed file only)\n"

  local choice
  while true; do
    read -r -p "  Choose [0-${#backups[@]}]: " choice || { choice=0; break; }
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= ${#backups[@]} )) && break
    warn "Invalid choice"
  done

  remove_file "$file"

  if (( choice > 0 )); then
    local selected="${backups[$((choice - 1))]}"
    mv -- "$selected" "$file"
    say "Restored: $file (from ${selected##*.bak.})"
  fi

  # Clean up remaining backups.  The restored one was moved away, so skip it —
  # a bare `[[ -e ]] &&` here would end the loop body with status 1 and trip
  # `set -e` whenever the user restored the last entry in the list.
  for b in "${backups[@]}"; do
    [[ -e "$b" ]] || continue
    rm -f -- "$b"
    say "Cleaned up backup: $b"
  done
}

[[ $EUID -eq 0 ]] || { err "Run with sudo/root."; exit 1; }

REMOVE_ALL=0
[[ "${1:-}" == "--all" ]] && REMOVE_ALL=1

say "AMDGPU warmfix uninstallation"

# ---------------------------------------------------------------------------
# 1) Stop and disable services
# ---------------------------------------------------------------------------
for svc in amdgpu-warmfix.service t2fanrd-resume.service t2fanrd.service applesmc-late.service; do
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
offer_restore "${drop_dir}/10-amdgpu-warmfix.conf"
# Remove the drop-in directory if empty
rmdir -- "$drop_dir" 2>/dev/null && say "Removed empty dir: $drop_dir" || true

# ---------------------------------------------------------------------------
# 3) Remove service units
# ---------------------------------------------------------------------------
for f in amdgpu-warmfix.service t2fanrd-resume.service t2fanrd.service applesmc-late.service; do
  offer_restore "/etc/systemd/system/$f"
done

# ---------------------------------------------------------------------------
# 4) Remove scripts and binaries from /usr/local/bin/
# ---------------------------------------------------------------------------
for f in amdgpu-pci-reset-load.sh amdgpu-check.sh t2-gpu-status.sh t2-wait-sysfs.sh t2fanrd; do
  offer_restore "/usr/local/bin/$f"
done

# Installers before 2026-07 copied uninstall.sh here too.  Unlinking a running
# script is safe on Linux — bash keeps reading from the open fd.
if [[ "$(realpath -- "${BASH_SOURCE[0]}")" != "/usr/local/bin/uninstall.sh" ]]; then
  remove_file "/usr/local/bin/uninstall.sh"
fi
for b in /usr/local/bin/uninstall.sh.bak.*; do
  [[ -e "$b" ]] || continue   # no match: bash leaves the pattern literal
  remove_file "$b"
done

# ---------------------------------------------------------------------------
# 5) Remove system config files
# ---------------------------------------------------------------------------
offer_restore "/etc/modprobe.d/amdgpu.conf"
offer_restore "/etc/udev/rules.d/99-amdgpu-t2.rules"
offer_restore "/etc/udev/rules.d/99-t2-usb.rules"
offer_restore "/etc/dracut.conf.d/10-amdgpu-warmfix.conf"
offer_restore "/etc/dracut.conf.d/20-amdgpu-t2-cmdline.conf"

# ---------------------------------------------------------------------------
# 6) Optionally remove ACPI image and t2fanrd config
# ---------------------------------------------------------------------------
if (( REMOVE_ALL )); then
  remove_file "/boot/acpi_override.img"
  remove_file "/etc/t2fand.conf"
  # Written by installers before 2026-07; t2fanrd never read it.
  remove_file "/etc/t2fanrd.conf"
else
  warn "Kept /boot/acpi_override.img and /etc/t2fand.conf (use --all to remove)"
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
