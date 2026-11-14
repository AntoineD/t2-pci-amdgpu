#!/usr/bin/env bash
# uninstall.sh — Remove AMDGPU warmfix components installed by install.sh
#
# Usage: sudo ./uninstall.sh [--all] [--dry-run]
#
#   --all       Also remove /boot/acpi_override.img, /etc/t2fand.conf
#               (plus the legacy /etc/t2fanrd.conf, which t2fanrd never read),
#               /etc/t2-pci-amdgpu.conf (the saved GPU DPM level)
#               and /var/lib/t2-pci-amdgpu.  The image is kept for as long as
#               GRUB still loads it: see step 6.
#   --dry-run   Show what would be removed and which steps would remain,
#               without changing anything
#
set -Eeuo pipefail

[[ "${DEBUG:-0}" == "1" ]] && { PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '; set -x; }

say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; }

REMOVE_ALL=0
DRY_RUN=0
while (( $# )); do
  case "$1" in
    --all)     REMOVE_ALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# Root even for --dry-run: grubenv, the boot entries and the initramfs images
# it has to inspect are all root-only.
[[ $EUID -eq 0 ]] || { err "Run with sudo/root."; exit 1; }

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=t2-grub-common.bash
source "${SRC_DIR}/t2-grub-common.bash" || { err "Missing ${SRC_DIR}/t2-grub-common.bash"; exit 1; }
[[ -f "${SRC_DIR}/t2-tuned-hda.conf.in" ]] || { err "Missing ${SRC_DIR}/t2-tuned-hda.conf.in"; exit 1; }
# shellcheck source=t2-tuned.bash
source "${SRC_DIR}/t2-tuned.bash" || { err "Missing ${SRC_DIR}/t2-tuned.bash"; exit 1; }

ACPI_IMG="/boot/${ACPI_IMG_NAME}"

removed_any=0
remove_file() {
  [[ -e "$1" ]] || return 0
  if (( DRY_RUN )); then say "Would remove: $1"; removed_any=1; return 0; fi
  rm -f -- "$1"
  removed_any=1
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

  if (( DRY_RUN )); then
    remove_file "$file"
    say "Would offer ${#backups[@]} backup(s) of $file to restore, newest ${backups[0]##*.bak.}"
    return 0
  fi

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

(( DRY_RUN )) && say "=== DRY RUN — no changes will be made ==="
say "AMDGPU warmfix uninstallation"

# ---------------------------------------------------------------------------
# 1) Stop and disable services
# ---------------------------------------------------------------------------
for svc in amdgpu-warmfix.service t2fanrd-resume.service t2fanrd.service applesmc-late.service; do
  if systemctl is-enabled "$svc" &>/dev/null; then
    if (( DRY_RUN )); then say "Would disable: $svc"; else systemctl disable "$svc"; say "Disabled: $svc"; fi
  fi
  if systemctl is-active "$svc" &>/dev/null; then
    if (( DRY_RUN )); then say "Would stop: $svc"; else systemctl stop "$svc"; say "Stopped: $svc"; fi
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
if ! (( DRY_RUN )); then
  rmdir -- "$drop_dir" 2>/dev/null && say "Removed empty dir: $drop_dir" || true
fi

# ---------------------------------------------------------------------------
# 3) Remove service units
# ---------------------------------------------------------------------------
for f in amdgpu-warmfix.service t2fanrd-resume.service t2fanrd.service applesmc-late.service; do
  offer_restore "/etc/systemd/system/$f"
done
# Drop-in for the t2linux package's own t2fanrd unit
offer_restore "/etc/systemd/system/t2fanrd.service.d/10-t2-pci-amdgpu.conf"
if ! (( DRY_RUN )); then
  rmdir -- /etc/systemd/system/t2fanrd.service.d 2>/dev/null && say "Removed empty dir: /etc/systemd/system/t2fanrd.service.d" || true
fi
if [[ -x /usr/bin/t2fanrd ]]; then
  warn "The t2fanrd package stays installed but disabled; to run it without this"
  warn "project: sudo systemctl enable --now t2fanrd.service"
fi

# ---------------------------------------------------------------------------
# 4) Remove scripts and binaries from /usr/local/bin/
# ---------------------------------------------------------------------------
for f in amdgpu-pci-reset-load.sh amdgpu-check.sh t2-gpu-status.sh t2-wait-sysfs.sh t2-unit-state.sh t2-amd-nodes.sh t2-gpu-dpm.sh t2fanrd; do
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
offer_restore "/etc/modprobe.d/t2-applesmc.conf"
offer_restore "/etc/modprobe.d/t2-wifi-off.conf"
offer_restore "/etc/modprobe.d/amdgpu-navi10-imac.conf"
offer_restore "/etc/udev/rules.d/99-amdgpu-t2.rules"
offer_restore "/etc/udev/rules.d/99-t2-usb.rules"
offer_restore "/etc/udev/rules.d/99-t2-wifi-off.rules"
wp_removed=0
for f in /etc/wireplumber/wireplumber.conf.d/50-t2-stereo-speakers.conf \
         /etc/wireplumber/wireplumber.conf.d/51-t2-mic.conf; do
  [[ -e "$f" ]] || continue
  offer_restore "$f"
  wp_removed=1
done
if (( wp_removed )); then
  say "Speakers and microphone: log out and back in, or run 'systemctl --user restart wireplumber' as your user"
fi
if [[ -e /etc/environment.d/90-t2-sw-cursor.conf ]]; then
  offer_restore "/etc/environment.d/90-t2-sw-cursor.conf"
  say "Cursor: the hardware cursor comes back at the next login"
fi
# tuned overrides from t2-tuned-hda.conf.in.  Only files carrying our marker
# go, so a profile the user wrote under the same name stays; and only while
# their settings are still the generated ones (tuned_is_pristine), so an edit
# made to our file, or kept in one of its backups, is not lost.
tuned_removed=0
for d in "${TUNED_ETC_DIR}"/*/; do
  [[ -d "$d" ]] || continue   # no nullglob here: an unmatched glob stays literal
  prof="$(basename "$d")"
  removed_here=0
  for f in "${d}tuned.conf" "${d}"tuned.conf.bak.*; do
    tuned_is_ours "$f" || continue
    if tuned_is_pristine "$f" "$prof"; then
      remove_file "$f"
      removed_here=1
      if [[ "$f" == "${d}tuned.conf" ]]; then tuned_removed=1; fi
    else
      warn "Keeping ${f}: its settings were edited — delete it by hand if unwanted"
    fi
  done
  if (( removed_here && ! DRY_RUN )); then rmdir --ignore-fail-on-non-empty -- "$d"; fi
done
(( tuned_removed )) && tuned_reload
offer_restore "/etc/dracut.conf.d/10-amdgpu-warmfix.conf"
offer_restore "/etc/dracut.conf.d/20-amdgpu-t2-cmdline.conf"

# ---------------------------------------------------------------------------
# 6) Optionally remove ACPI image and t2fanrd config
#
# The image must outlive every GRUB reference to it.  Fedora's blscfg adds
# each early_initrd file to the entry's initrd line without checking that it
# exists, and the x86 EFI `initrd` command loads nothing at all when one file
# fails to open.  No initramfs means no root filesystem, so deleting the image
# first leaves a machine that does not boot.
# ---------------------------------------------------------------------------
img_refs=()
initrd_custom="$(grub_var GRUB_EARLY_INITRD_LINUX_CUSTOM)"
names_acpi_img "$initrd_custom" && \
  img_refs+=("${GRUB_FILE}: GRUB_EARLY_INITRD_LINUX_CUSTOM=\"${initrd_custom}\"")
env_initrd="$(grubenv_var early_initrd)"
names_acpi_img "$env_initrd" && \
  img_refs+=("GRUB environment (grubenv): early_initrd=${env_initrd}")
grep -qs "$ACPI_IMG_NAME" "$grub_cfg" && img_refs+=("$grub_cfg")
for entry in /boot/loader/entries/*.conf; do
  [[ -r "$entry" ]] || continue
  grep -qs "^initrd.*${ACPI_IMG_NAME}" "$entry" && img_refs+=("$entry")
done

img_kept=0
if (( REMOVE_ALL )); then
  if [[ -e "$ACPI_IMG" ]] && (( ${#img_refs[@]} )); then
    img_kept=1
    warn "Kept $ACPI_IMG — GRUB still loads it, from:"
    printf '      %s\n' "${img_refs[@]}"
    warn "GRUB loads no initramfs at all when one of its files is missing, and"
    warn "the system then cannot mount its root filesystem.  Do the steps below,"
    warn "then run this again with --all to delete the image."
  else
    remove_file "$ACPI_IMG"
  fi
  remove_file "/etc/t2fand.conf"
  # Written by installers before 2026-07; t2fanrd never read it.
  remove_file "/etc/t2fanrd.conf"
  # Saved by t2-gpu-dpm.sh; only 99-amdgpu-t2.rules, removed above, reads it.
  remove_file "/etc/t2-pci-amdgpu.conf"
  # Firmware version the Thunderbolt patch was made on; meaningless without
  # the image above.
  if [[ -d /var/lib/t2-pci-amdgpu ]] && (( ! img_kept )); then
    if (( DRY_RUN )); then
      say "Would remove: /var/lib/t2-pci-amdgpu"
    else
      rm -rf -- /var/lib/t2-pci-amdgpu
      say "Removed: /var/lib/t2-pci-amdgpu"
    fi
  fi
else
  warn "Kept $ACPI_IMG, /etc/t2fand.conf and /etc/t2-pci-amdgpu.conf (use --all to remove)"
fi

# ---------------------------------------------------------------------------
# 7) Reload daemons
# ---------------------------------------------------------------------------
if ! (( DRY_RUN )); then
  systemctl daemon-reload
  udevadm control --reload-rules
  say "systemd and udev reloaded"
fi

say "Uninstallation complete."

# ---------------------------------------------------------------------------
# Outstanding steps — the exact commands for this system, and only those
# still needed, so a re-run after doing them prints none.
# ---------------------------------------------------------------------------
bls=0
grub_bls && bls=1
have_grubby=0
command -v grubby &>/dev/null && have_grubby=1

# Kernel parameters install.sh asked for that are still set somewhere
present=()
cmdline_default="$(grub_var GRUB_CMDLINE_LINUX)"
entry_args="$(boot_entry_args)"
for p in "${REQUIRED_PARAMS[@]}"; do
  if has_word "$p" "$cmdline_default" || has_word "$p" "${entry_args//$'\n'/ }"; then
    present+=("$p")
  fi
done
cmdline_rest=()
read -ra cmdline_words <<<"$cmdline_default"
for w in "${cmdline_words[@]}"; do
  has_word "$w" "${present[*]:-}" || cmdline_rest+=("$w")
done

# Images still carrying this project's dracut or modprobe config
stale_initramfs=0
if command -v lsinitrd &>/dev/null; then
  for img in /boot/initramfs-*.img; do
    [[ -e "$img" ]] || continue
    for f in etc/modprobe.d/amdgpu.conf etc/modprobe.d/t2-wifi-off.conf etc/modprobe.d/amdgpu-navi10-imac.conf; do
      [[ -n "$(lsinitrd -f "$f" "$img" 2>/dev/null)" ]] && stale_initramfs=1
    done
    if [[ "$(lsinitrd -f etc/cmdline.d/20-force_drivers.conf "$img" 2>/dev/null)" == *rd.driver.pre=amdgpu* ]]; then
      stale_initramfs=1
    fi
  done
fi

n=0
step() { n=$((n + 1)); echo; echo "${n}. $*"; }

echo
echo "====== Remaining steps ======"
(( DRY_RUN )) && echo "(dry run: lists the steps a real run would leave)"

need_mkconfig=0

if names_acpi_img "$initrd_custom"; then
  step "Edit ${GRUB_FILE} — stop loading the ACPI override image:"
  rest="$(without_acpi_img "$initrd_custom")"
  if [[ -z "$rest" ]]; then
    echo "     Delete the line  GRUB_EARLY_INITRD_LINUX_CUSTOM=\"${initrd_custom}\""
  else
    echo "     GRUB_EARLY_INITRD_LINUX_CUSTOM=\"${rest}\""
  fi
  (( bls )) || need_mkconfig=1
fi

if (( ${#present[@]} )); then
  if (( bls && have_grubby )); then
    step "Remove the kernel parameters from every boot entry (grubby also updates ${GRUB_FILE}):"
    echo
    echo "     sudo grubby --update-kernel=ALL --remove-args=\"${present[*]}\""
  else
    step "Remove the kernel parameters ${present[*]}:"
    if [[ "${cmdline_rest[*]:-}" != "$cmdline_default" ]]; then
      echo "     In ${GRUB_FILE}, replace the GRUB_CMDLINE_LINUX line with:"
      echo
      echo "       GRUB_CMDLINE_LINUX=\"${cmdline_rest[*]:-}\""
    fi
    if (( bls )); then
      echo "     grubby is not installed: also delete them from the options line of"
      echo "     each /boot/loader/entries/*.conf"
    else
      need_mkconfig=1
    fi
  fi
  echo "     (pci=noaer and pcie_aspm=off are general PCI settings; keep any you want.)"
fi

if names_acpi_img "$env_initrd"; then
  step "Clear the image from GRUB's environment block — grub2-mkconfig sets"
  echo "   early_initrd but never clears it:"
  echo
  rest="$(without_acpi_img "$env_initrd")"
  if [[ -z "$rest" ]]; then
    echo "     sudo grub2-editenv - unset early_initrd"
  else
    echo "     sudo grub2-editenv - set early_initrd=\"${rest}\""
  fi
fi

if grep -qs "$ACPI_IMG_NAME" "$grub_cfg"; then need_mkconfig=1; fi
if (( need_mkconfig )); then
  step "Regenerate the GRUB config (${boot_mode}):"
  echo
  echo "     sudo grub2-mkconfig -o ${grub_cfg}"
fi

for entry in /boot/loader/entries/*.conf; do
  [[ -r "$entry" ]] || continue
  if grep -qs "^initrd.*${ACPI_IMG_NAME}" "$entry"; then
    step "Remove ${ACPI_IMG_NAME} from the initrd line of ${entry}"
  fi
done

if (( stale_initramfs )); then
  step "Rebuild every initramfs — they still embed this project's dracut and modprobe config:"
  echo
  echo "     sudo dracut -f --regenerate-all"
fi

if (( img_kept )); then
  step "Delete the ACPI override image, now that nothing loads it:"
  echo
  echo "     sudo ${SRC_DIR}/uninstall.sh --all"
fi

if (( n || removed_any )); then
  step "Reboot."
else
  echo
  say "Nothing left to do."
fi
echo
