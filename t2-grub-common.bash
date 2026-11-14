# shellcheck shell=bash disable=SC2034  # variables here are used by the scripts that source it
# t2-grub-common.bash — GRUB facts shared by install.sh and uninstall.sh.
#
# Sourced, never run.  Deliberately not a *.sh file: install.sh copies every
# *.sh into /usr/local/bin as a runtime tool, and this is installer code.
#
# Most of what it reads is root-only on Fedora: grubenv, /boot/loader/entries,
# grub.cfg and `grubby --info`.  Without root the helpers return nothing.

GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"   # overridable for testing
ACPI_IMG_NAME="acpi_override.img"
# Kernel parameters install.sh requires.  uninstall.sh offers to remove them.
REQUIRED_PARAMS=(pci=noaer pcie_aspm=off amdgpu.aspm=0 amdgpu.runpm=0)

# Since Fedora 34 the EFI partition holds only a stub grub.cfg that hands off
# to /boot/grub2/grub.cfg (it calls `configfile`).  Pointing grub2-mkconfig at
# the stub overwrites it with a full config that kernel updates never refresh.
# Use the EFI path only on a system where it really is the config.
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

# grub_bls — the system boots BootLoaderSpec entries (Fedora's default)
grub_bls() { [[ "$(grub_var GRUB_ENABLE_BLSCFG)" == "true" ]]; }

# grubenv_var NAME — value of NAME in GRUB's environment block (grubenv)
grubenv_var() {
  command -v grub2-editenv &>/dev/null || return 0
  grub2-editenv - list 2>/dev/null | sed -n "s/^$1=//p" | tail -n1 || true
}

# has_word WORD STRING — WORD is one of STRING's whitespace-separated words
has_word() { [[ " $2 " == *[[:space:]]"$1"[[:space:]]* ]]; }

# nomodeset_blocks STRING — STRING has nomodeset and nothing overrides it.  Any
# amdgpu.modeset=<value> word re-enables the amdgpu probe (CLAUDE.md, layer 4),
# the same combination the warmfix unit's conditions accept.
nomodeset_blocks() {
  local w words
  has_word nomodeset "$1" || return 1
  read -ra words <<<"$1"
  for w in "${words[@]}"; do
    [[ "$w" == amdgpu.modeset=* ]] && return 1
  done
  return 0
}

# names_acpi_img STRING — one of STRING's words is the ACPI override image,
# bare (early_initrd, GRUB_EARLY_INITRD_LINUX_CUSTOM) or as a path (initrd lines)
names_acpi_img() {
  local w words
  # read -a, not an unquoted expansion: install.sh runs with nullglob set.
  read -ra words <<<"$1"
  for w in "${words[@]}"; do
    [[ "${w##*/}" == "$ACPI_IMG_NAME" ]] && return 0
  done
  return 1
}

# without_acpi_img STRING — STRING's words minus the ACPI override image
without_acpi_img() {
  local w words out=()
  read -ra words <<<"$1"
  for w in "${words[@]}"; do
    [[ "${w##*/}" == "$ACPI_IMG_NAME" ]] || out+=("$w")
  done
  printf '%s' "${out[*]}"
}

# boot_entry_args — the kernel command line of each boot entry GRUB offers for
# this system, one per line.
#   BLS:     grubby --info=ALL, or the entries' own `options` lines when
#            grubby is not installed.
#   non-BLS: `linux` lines in grub.cfg's 10_linux section only.  Entries
#            30_os-prober found for other systems are not ours to judge.
boot_entry_args() {
  local line kw rest
  if grub_bls; then
    if command -v grubby &>/dev/null; then
      while IFS= read -r line; do
        [[ "$line" == args=* ]] || continue
        line="${line#args=}"; line="${line#\"}"; line="${line%\"}"
        printf '%s\n' "$line"
      done < <(grubby --info=ALL 2>/dev/null)
    else
      for line in /boot/loader/entries/*.conf; do
        [[ -r "$line" ]] || continue
        sed -n 's/^options[[:space:]]\+//p' "$line"
      done
    fi
  elif [[ -r "$grub_cfg" ]]; then
    while read -r kw rest; do
      [[ "$kw" == linux* ]] && printf '%s\n' "$rest"
    done < <(sed -n '\|^### BEGIN /etc/grub.d/10_linux ###|,\|^### END /etc/grub.d/10_linux ###|p' "$grub_cfg")
  fi
  # Not the last test's status: callers run under set -e, and a grub.cfg
  # whose last line is not a `linux` line would read as a failure.
  return 0
}
