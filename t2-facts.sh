#!/usr/bin/env bash
# t2-facts.sh — facts install.sh and amdgpu-check.sh both judge, in one place.
#
# Usage: t2-facts.sh navi10-imac PCI_DEVICE_DIR
#          exit 0 and print "device:subsystem_vendor:subsystem_device" when the
#          GPU is a Navi 10 iMac20,x board (5700: 731b/106b:021a, 5700 XT:
#          7319/106b:021b); exit 1 otherwise.  These need amdgpu-navi10-imac.conf.
#        t2-facts.sh mic-lv2-missing
#          print the packages whose LV2 file the mic filter needs and that is
#          absent, one per line (nothing when all are present)
#        t2-facts.sh macsmc
#          exit 0 when the running kernel ships macsmc_acpi (the SMC's own curve
#          then drives the fan).  The units keep their own inline ExecCondition=.
set -Eeuo pipefail

# The mic filter's limiter: file → package.
declare -A T2_MIC_LV2=(
  [/usr/lib64/lv2/fast_lookahead_limiter-swh.lv2/plugin-Linux.so]=lv2-swh-plugins
  [/usr/lib64/spa-0.2/filter-graph/libspa-filter-graph-plugin-lv2.so]=pipewire-module-filter-chain-lv2
)

case "${1:-}" in
  navi10-imac)
    ids=""
    for f in device subsystem_vendor subsystem_device; do
      ids+="$(cat "${2:?PCI device dir}/$f" 2>/dev/null):"
    done
    case "$ids" in
      0x731b:0x106b:0x021a:|0x7319:0x106b:0x021b:) echo "${ids%:}"; exit 0 ;;
    esac
    exit 1
    ;;
  mic-lv2-missing)
    for f in "${!T2_MIC_LV2[@]}"; do
      [[ -e "$f" ]] || echo "${T2_MIC_LV2[$f]}"
    done | sort
    ;;
  macsmc)
    modinfo -n macsmc_acpi &>/dev/null
    ;;
  *)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
