#!/usr/bin/env bash
# t2-amd-nodes.sh — /dev/dri paths of the DRM nodes under AMD VGA functions.
#
# Shared by amdgpu-check.sh and t2-gpu-status.sh.  Only nodes under an AMD VGA
# function count: a global /dev/dri glob also sees i915 (iGPU-enabled
# MacBookPros) or an eGPU, and would call a dead dGPU healthy.
#
# Usage: t2-amd-nodes.sh renderD|card   (space-separated, empty if none)
set -Eeuo pipefail

for d in /sys/bus/pci/devices/*; do
  read -r ven 2>/dev/null < "$d/vendor" || continue
  read -r cls 2>/dev/null < "$d/class"  || continue
  [[ "$ven" == "0x1002" && "$cls" == 0x0300* ]] || continue
  for n in "$d"/drm/"$1"*; do
    [[ -e "$n" ]] && printf '/dev/dri/%s ' "${n##*/}"
  done
done
exit 0
