#!/usr/bin/env bash
# t2-gpu-dpm.sh — show or set the AMD GPU's DPM (dynamic power management) level.
#
# Usage: t2-gpu-dpm.sh                  show the saved and the live level
#        sudo t2-gpu-dpm.sh low|auto|high
#        t2-gpu-dpm.sh saved            print only the level saved for boot
#
#   low   300 MHz core, the default: the coolest and slowest
#   auto  the driver scales the core with load; same idle power as low here
#   high  core held at its top clock
#
# Setting a level saves it as T2_GPU_DPM in /etc/t2-pci-amdgpu.conf, which
# 99-amdgpu-t2.rules reads at every boot, and applies it at once.  Without
# the file the rule pins "low".  Measured on iMac20,2 (Radeon Pro 5700,
# glmark2 terrain at 2560x1440): idle 10 W either way; under load "auto" ran
# 45 W and 176-181 FPS against 23 W and 125 FPS on "low", and 5 min of it
# took the junction to 66 °C (critical 105 °C).
#
# A running LACT daemon (lactd) also sets this level; with lactd enabled,
# set the level in LACT instead.
set -Eeuo pipefail

CONF=/etc/t2-pci-amdgpu.conf
LEVELS="low auto high"

say()  { printf "\033[1;36m[•]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; }

usage() { sed -n '4,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# The level the rule will apply at boot.  Same reading as udev's: the last
# T2_GPU_DPM= line, optional quotes, anything outside $LEVELS means "low".
saved_level() {
  local v=""
  [[ -r "$CONF" ]] && v=$(sed -n 's/^[[:space:]]*T2_GPU_DPM=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$CONF" | tail -n1)
  case " $LEVELS " in *" $v "*) [[ -n "$v" ]] && { echo "$v"; return 0; } ;; esac
  echo low
}

# Card devices the rule targets: card<N> whose PCI device amdgpu drives.
gpu_devs() {
  local c drv
  for c in /sys/class/drm/card[0-9]*; do
    [[ "${c##*/}" == *-* ]] && continue
    drv=$(readlink -f "$c/device/driver" 2>/dev/null) || continue
    [[ "${drv##*/}" == amdgpu && -e "$c/device/power_dpm_force_performance_level" ]] || continue
    readlink -f "$c/device"
  done
  return 0
}

show() {
  local dev any=0 sclk
  if [[ -e "$CONF" ]]; then
    say "Saved level: $(saved_level) ($CONF)"
  else
    say "Saved level: low (default; $CONF does not exist)"
  fi
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    any=1
    sclk=$(grep -m1 '\*' "$dev/pp_dpm_sclk" 2>/dev/null | awk '{print $2}')
    say "Live level:  $(cat "$dev/power_dpm_force_performance_level") on ${dev##*/} (core now ${sclk:-?})"
  done < <(gpu_devs)
  (( any )) || warn "No GPU driven by amdgpu — nothing to show live"
  if systemctl is-active --quiet lactd 2>/dev/null; then
    warn "lactd is running and sets this level too; its setting wins when it applies one"
  fi
}

(( $# )) || { show; exit 0; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  status)    show; exit 0 ;;
  saved)     saved_level; exit 0 ;;
esac
level=$1
case " $LEVELS " in
  *" $level "*) ;;
  *) err "Unknown level: $level (want one of: $LEVELS)"; usage >&2; exit 1 ;;
esac
(( EUID == 0 )) || { err "Setting the level needs root: sudo $0 $level"; exit 1; }

# Save: replace the T2_GPU_DPM line, keep anything else in the file.
tmp=$(mktemp "${CONF}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
if [[ -e "$CONF" ]]; then
  grep -v '^[[:space:]]*T2_GPU_DPM=' "$CONF" > "$tmp" || true
else
  cat > "$tmp" <<'EOF'
# /etc/t2-pci-amdgpu.conf — read by /etc/udev/rules.d/99-amdgpu-t2.rules at
# every boot (udev IMPORT{file}: KEY=value lines, no trailing comments).
# T2_GPU_DPM: GPU DPM level, low (default), auto or high.
# Change it with: sudo t2-gpu-dpm.sh low|auto|high
EOF
fi
printf 'T2_GPU_DPM=%s\n' "$level" >> "$tmp"
chmod 0644 "$tmp"
mv -f -- "$tmp" "$CONF"
command -v restorecon >/dev/null && restorecon -- "$CONF" 2>/dev/null || true
say "Saved T2_GPU_DPM=$level in $CONF"

rc=0
applied=0
while read -r dev; do
  [[ -n "$dev" ]] || continue
  if echo "$level" > "$dev/power_dpm_force_performance_level"; then
    applied=1
    say "Applied $level to ${dev##*/}"
  else
    err "Could not write $level to ${dev##*/} — it applies at next boot"
    rc=1
  fi
done < <(gpu_devs)
(( applied || rc )) || warn "No GPU driven by amdgpu right now; the level applies when it binds"
exit "$rc"
