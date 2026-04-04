#!/usr/bin/env bash
# t2-gpu-status.sh — quick status check for T2 GPU workaround - version 1.0
set -euo pipefail

echo "=== AMDGPU Warmfix Status ==="

# render node present ?
if ls /dev/dri/renderD* >/dev/null 2>&1; then
    echo "Render node: present ✔"
else
    echo "Render node: missing ✘"
fi

# GPU init count from dmesg
count=$(dmesg | grep -c "amdgpu .*: .*resetting")
inits=$(dmesg | grep -c "\[drm\] Initialized amdgpu")
total=$((count + inits))
echo "GPU init events this boot: $total (resets=$count, successful inits=$inits)"

# warmfix logs
echo
echo "--- Last boot warmfix log ---"
journalctl -b -t amdgpu-warmfix | tail -n 20

# service state
echo
echo "--- Services ---"
for svc in amdgpu-warmfix.service applesmc-late.service t2fanrd.service; do
    type=$(systemctl show -p Type --value "$svc" 2>/dev/null)
    state=$(systemctl is-enabled "$svc" 2>/dev/null)
    active=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$type" == "oneshot" && "$active" == "inactive" ]]; then
        active="ran-once"
    fi
    printf "%-25s enabled=%-7s active=%s\n" "$svc" "$state" "$active"
done

