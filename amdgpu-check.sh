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

# --- Render node -------------------------------------------------------------
if ls /dev/dri/renderD* &>/dev/null 2>&1; then
  ok  "Render node: $(ls /dev/dri/renderD* | tr '\n' ' ')"
else
  fail "Render node: missing"
  gpu_ok=0
fi

# --- Card node ---------------------------------------------------------------
if ls /dev/dri/card* &>/dev/null 2>&1; then
  ok  "Card node:   $(ls /dev/dri/card* | tr '\n' ' ')"
else
  fail "Card node:   missing"
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
for svc in amdgpu-warmfix.service applesmc-late.service t2fanrd.service t2fanrd-resume.service; do
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "not-found")
  active=$(systemctl  is-active  "$svc" 2>/dev/null || echo "not-found")
  type=$(systemctl show -p Type --value "$svc" 2>/dev/null || true)
  if [[ "$type" == "oneshot" && "$active" == "inactive" ]]; then
    # Empty start timestamp = never ran this boot (expected for t2fanrd-resume
    # until the machine has suspended once).
    started=$(systemctl show -p ExecMainStartTimestamp --value "$svc" 2>/dev/null || true)
    [[ -n "$started" ]] && active="ran-once" || active="not-run"
  fi
  printf "  %-32s enabled=%-12s active=%s\n" "$svc" "$enabled" "$active"
done

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
      sleep 3
      say "/dev/dri/ after restart:"
      ls /dev/dri/ 2>/dev/null || warn "Still empty"
    fi
  fi
else
  echo
  ok "GPU looks healthy."
fi
