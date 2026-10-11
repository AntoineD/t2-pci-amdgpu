#!/usr/bin/env bash
# t2-unit-state.sh — one status line per T2 workaround unit.
#
# Shared by amdgpu-check.sh and t2-gpu-status.sh so the unit list and the
# oneshot logic live in one place.
#
# Usage: t2-unit-state.sh [UNIT...]   (default: every unit install.sh enables)
set -Eeuo pipefail

T2_UNITS=(amdgpu-warmfix.service applesmc-late.service t2fanrd.service t2fanrd-resume.service)
(( $# )) || set -- "${T2_UNITS[@]}"

# A oneshot without RemainAfterExit= reads "inactive" both before it has run
# and after.  ExecMainStartTimestamp cannot tell the two apart: systemd unloads
# an inactive unit that nothing loaded references — t2fanrd-resume, once each
# resume is over — and an unloaded unit reports an empty timestamp, so a hook
# that fired twice this boot showed up as never run.  The journal keeps the
# record across the unload.
ran_this_boot() {
  # No -q/-m on grep: stopping early would SIGPIPE journalctl and pipefail
  # would turn a match into a failure.
  journalctl -b -o cat -u "$1" 2>/dev/null | grep -E '^(Finished|Failed to start) ' >/dev/null
}

# Without root or journal-group access journalctl shows only the user's own
# journal, and every oneshot would look never-run.  Say so instead.
journal_readable() {
  [[ -n "$(journalctl -b -q -n 1 -o cat _PID=1 2>/dev/null)" ]]
}

for svc; do
  load=$(systemctl show -p LoadState --value "$svc" 2>/dev/null || true)
  if [[ -z "$load" || "$load" == not-found ]]; then
    printf "%-24s enabled=%-9s active=%s\n" "$svc" "not-found" "not-found"
    continue
  fi
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)
  active=$(systemctl is-active "$svc" 2>/dev/null || true)
  type=$(systemctl show -p Type --value "$svc" 2>/dev/null || true)
  if [[ "$type" == oneshot && "$active" == inactive ]]; then
    # not-run is normal for t2fanrd-resume until the first suspend/resume.
    if ! journal_readable; then
      active="inactive (run as root to tell ran-once from not-run)"
    elif ran_this_boot "$svc"; then
      active="ran-once"
    else
      active="not-run"
    fi
  fi
  printf "%-24s enabled=%-9s active=%s\n" "$svc" "${enabled:-unknown}" "${active:-unknown}"
done
