#!/usr/bin/env bash
# t2-gpu-status.sh — quick status check for T2 GPU workaround - version 1.0
set -Eeuo pipefail

echo "=== AMDGPU Warmfix Status ==="

# render node present ?  Only one under the AMD VGA function counts — a global
# /dev/dri glob would also see i915 or an eGPU.
render=""
for d in /sys/bus/pci/devices/*; do
    [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x1002" && "$(cat "$d/class" 2>/dev/null)" == 0x0300* ]] || continue
    for n in "$d"/drm/renderD*; do
        [[ -e "$n" ]] && render+="/dev/dri/${n##*/} "
    done
done
if [[ -n "$render" ]]; then
    echo "Render node: present ✔ ($render)"
else
    echo "Render node: missing ✘"
fi

# GPU init count from dmesg
count=$(dmesg | grep -c "amdgpu .*: .*resetting" || true)
inits=$(dmesg | grep -c "\[drm\] Initialized amdgpu" || true)
total=$((count + inits))
echo "GPU init events this boot: $total (resets=$count, successful inits=$inits)"

# warmfix logs
echo
echo "--- Last boot warmfix log ---"
journalctl -b -u amdgpu-warmfix.service --no-pager | tail -n 20

# service state
echo
echo "--- Services ---"
"$(dirname "${BASH_SOURCE[0]}")/t2-unit-state.sh"
