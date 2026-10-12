#!/usr/bin/env bash
# t2-gpu-status.sh — quick status check for T2 GPU workaround - version 1.0
set -Eeuo pipefail

echo "=== AMDGPU Warmfix Status ==="

# render node present ?  Only one under the AMD VGA function counts — a global
# /dev/dri glob would also see i915 or an eGPU.
render=$("$(dirname "${BASH_SOURCE[0]}")/t2-amd-nodes.sh" renderD)
if [[ -n "$render" ]]; then
    echo "Render node: present ✔ ($render)"
else
    echo "Render node: missing ✘"
fi

# GPU init count from the kernel journal.  Not dmesg: it fails for non-root
# under kernel.dmesg_restrict, and an empty read must not pass for zero events.
klog=$(journalctl -k -b -o cat --no-pager 2>/dev/null || true)
if [[ -z "$klog" ]]; then
    echo "GPU init events this boot: unknown (kernel journal not readable — run as root)"
else
    count=$(grep -c "amdgpu .*resetting" <<<"$klog" || true)
    inits=$(grep -c "\[drm\] Initialized amdgpu" <<<"$klog" || true)
    total=$((count + inits))
    echo "GPU init events this boot: $total (resets=$count, successful inits=$inits)"
fi

# warmfix logs
echo
echo "--- Last boot warmfix log ---"
journalctl -b -u amdgpu-warmfix.service --no-pager | tail -n 20

# service state
echo
echo "--- Services ---"
"$(dirname "${BASH_SOURCE[0]}")/t2-unit-state.sh"
