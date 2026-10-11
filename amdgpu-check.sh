#!/usr/bin/env bash
# amdgpu-check.sh — AMD GPU health check and optional live warmfix re-trigger
# Run as root to enable the re-trigger option.

say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[✔]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[✘]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }

gpu_ok=1

echo "=== AMDGPU T2 Health Check ==="
echo

# --- AMD GPU DRM nodes ---------------------------------------------------------
# Only nodes under an AMD VGA function count.  A global /dev/dri glob also sees
# i915 (iGPU-enabled MacBookPros) or an eGPU, and would call a dead dGPU healthy.
amd_nodes() {  # amd_nodes renderD|card — /dev/dri paths of AMD VGA DRM nodes
  local d n ven cls
  for d in /sys/bus/pci/devices/*; do
    read -r ven 2>/dev/null < "$d/vendor" || continue
    read -r cls 2>/dev/null < "$d/class"  || continue
    [[ "$ven" == "0x1002" && "$cls" == 0x0300* ]] || continue
    for n in "$d"/drm/"$1"*; do
      [[ -e "$n" ]] && printf '/dev/dri/%s ' "${n##*/}"
    done
  done
}

render=$(amd_nodes renderD)
if [[ -n "$render" ]]; then
  ok  "Render node: $render"
else
  fail "Render node: missing (none under an AMD VGA device)"
  gpu_ok=0
fi

card=$(amd_nodes card)
if [[ -n "$card" ]]; then
  ok  "Card node:   $card"
else
  fail "Card node:   missing (none under an AMD VGA device)"
  gpu_ok=0
fi

# --- amdgpu kernel module ----------------------------------------------------
if lsmod | grep -q '^amdgpu'; then
  ok  "amdgpu module: loaded"
else
  fail "amdgpu module: not loaded"
  gpu_ok=0
fi

# --- radeon must NOT be loaded -----------------------------------------------
if lsmod | grep -q '^radeon'; then
  warn "radeon module is loaded — may conflict with amdgpu"
else
  ok  "radeon module: not loaded (good)"
fi

# --- GPU init events from dmesg ----------------------------------------------
resets=$(dmesg 2>/dev/null | grep -c "amdgpu .*resetting" || true)
inits=$(dmesg  2>/dev/null | grep -c "\[drm\] Initialized amdgpu" || true)
echo
say "GPU init events this boot: resets=${resets}  successful_inits=${inits}"

# --- Warmfix service log -----------------------------------------------------
echo
say "Warmfix service log (last 15 lines):"
journalctl -b -u amdgpu-warmfix.service -n 15 --no-pager 2>/dev/null || \
  warn "No warmfix journal entries found"

# --- Service states ----------------------------------------------------------
echo
say "Service states:"
"$(dirname "${BASH_SOURCE[0]}")/t2-unit-state.sh" | sed 's/^/  /'

# --- Power management state --------------------------------------------------
echo
say "AMD PCI device power states:"
for d in /sys/bus/pci/devices/*; do
  [[ -e "$d/vendor" ]] || continue
  read -r ven 2>/dev/null < "$d/vendor" || continue
  [[ "$ven" == "0x1002" ]] || continue
  ctrl=$(cat "$d/power/control"  2>/dev/null || echo "unknown")
  status=$(cat "$d/power/runtime_status" 2>/dev/null || echo "unknown")
  printf "  %-20s  control=%-6s  runtime_status=%s\n" \
    "$(basename "$d")" "$ctrl" "$status"
done

# --- Optional: live re-trigger -----------------------------------------------
if (( gpu_ok == 0 )); then
  echo
  warn "GPU appears unhealthy. Attempt live warmfix re-run?"
  read -r -p "  [y/N] " ans || true
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    if [[ $EUID -ne 0 ]]; then
      warn "Need root. Run: sudo systemctl restart amdgpu-warmfix.service"
    else
      say "Restarting amdgpu-warmfix.service ..."
      systemctl restart amdgpu-warmfix.service
      render=$(amd_nodes renderD)
      if [[ -n "$render" ]]; then
        ok "AMD render node after restart: $render"
      else
        fail "Still no AMD render node — see: journalctl -b -u amdgpu-warmfix.service"
      fi
    fi
  fi
else
  echo
  ok "GPU looks healthy."
fi
