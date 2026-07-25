#!/usr/bin/env bash
# t2-wait-sysfs.sh — block until a sysfs path matching any given glob appears.
#
# Replaces `udevadm settle` (and Wants=systemd-udev-settle.service) in the T2
# units.  settle is a global barrier: it waits for the whole coldplug queue to
# drain — 0.77 s on iMac20,2 — and still does not promise that the one device
# the unit cares about is there.  systemd logs a deprecation warning naming any
# unit that pulls it in.  Waiting on the exact path is faster and stricter.
#
# Usage: t2-wait-sysfs.sh [-t SECONDS] GLOB [GLOB...]
#        exits 0 on the first glob that matches, 1 on timeout.
set -Eeuo pipefail
shopt -s nullglob

timeout=10
if [[ "${1:-}" == "-t" ]]; then
  timeout="${2:?-t needs a value}"
  shift 2
fi
(( $# )) || { echo "usage: ${0##*/} [-t SECONDS] GLOB [GLOB...]" >&2; exit 2; }

deadline=$(( SECONDS + timeout ))
while :; do
  for pattern in "$@"; do
    # shellcheck disable=SC2206  # word splitting is the point: expand the glob
    matches=( $pattern )
    if (( ${#matches[@]} )); then
      echo "${0##*/}: ready after ${SECONDS}s: ${matches[0]}"
      exit 0
    fi
  done
  (( SECONDS >= deadline )) && break
  sleep 0.2
done

echo "${0##*/}: timed out after ${timeout}s waiting for: $*" >&2
exit 1
