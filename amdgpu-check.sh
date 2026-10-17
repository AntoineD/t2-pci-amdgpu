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
# Only nodes under an AMD VGA function count — see t2-amd-nodes.sh.
amd_nodes() { "$(dirname "${BASH_SOURCE[0]}")/t2-amd-nodes.sh" "$1"; }

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

# --- Installed kernels with the broken imac5k_table quirk ---------------------
# 7.2.9-310.t2 added an iMac20,x DMI quirk table, imac5k_table, without its {}
# terminator: 0x2b0 bytes = 2 x 344-byte entries and no sentinel.  The amdgpu
# probe reads past it, oopses and dies holding the device lock, and no
# userspace step recovers that boot.  Flag such a kernel before it is booted.
# Only 0x2b0 is known broken; any other size is reported but not judged.
echo
say "Installed kernels (amdgpu imac5k_table quirk):"
# The decompressed module is tens of MB; the EXIT trap removes it if the
# check is interrupted mid-scan.
imac5k_tmp=""
trap 'rm -f -- "$imac5k_tmp"' EXIT
imac5k_size() {  # imac5k_size <amdgpu.ko[.xz|.zst]> — hex size, empty if absent
  local ko=$1 rc=0
  imac5k_tmp=$(mktemp) || return 1
  case "$ko" in
    *.xz)  xz -dc "$ko"   >"$imac5k_tmp" 2>/dev/null ;;
    *.zst) zstd -dcq "$ko" >"$imac5k_tmp" 2>/dev/null ;;
    *)     cat "$ko"      >"$imac5k_tmp" ;;
  esac || rc=1
  (( rc )) || nm -S "$imac5k_tmp" 2>/dev/null | awk '$4 == "imac5k_table" { sub(/^0+/, "", $2); print $2 }'
  rm -f -- "$imac5k_tmp"
  imac5k_tmp=""
  return "$rc"
}
if ! command -v nm >/dev/null; then
  warn "nm not found (binutils) — cannot inspect installed kernels"
else
  default_kver=""
  if [[ $EUID -eq 0 ]] && command -v grubby >/dev/null; then
    default_kver=$(grubby --default-kernel 2>/dev/null)
    default_kver=${default_kver##*/vmlinuz-}
  fi
  for kdir in /lib/modules/*/; do
    kver=${kdir%/}; kver=${kver##*/}
    ko=$(compgen -G "${kdir}kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko*" | head -n1)
    [[ -n "$ko" ]] || continue
    tags=""
    [[ "$kver" == "$(uname -r)" ]] && tags+=" (running)"
    [[ "$kver" == "$default_kver" ]] && tags+=" (GRUB default)"
    if ! size=$(imac5k_size "$ko"); then
      warn "$kver$tags: could not decompress $ko"
    elif [[ -z "$size" ]]; then
      ok  "$kver$tags: no imac5k_table"
    elif [[ "$size" == "2b0" ]]; then
      fail "$kver$tags: BROKEN imac5k_table (0x2b0, no terminator) — GPU probe oopses; do not boot it"
      [[ "$kver" == "$default_kver" ]] && \
        fail "  It is the GRUB default. Pick another: grubby --set-default /boot/vmlinuz-<good version>"
    else
      warn "$kver$tags: imac5k_table size 0x$size — not a known-broken size, unverified"
    fi
  done
  [[ $EUID -eq 0 ]] || warn "Run as root to also check which kernel GRUB boots by default"
fi

# --- GPU init events from the kernel journal ---------------------------------
# Not dmesg: it fails for non-root under kernel.dmesg_restrict (Fedora's
# default), and the 256 KB printk buffer wraps on a long uptime.  A booted
# kernel always has messages, so an empty read means no journal access, which
# must not pass for "zero events" or "no ACPI table".
klog=$(journalctl -k -b -o cat --no-pager 2>/dev/null)
echo
if [[ -z "$klog" ]]; then
  warn "Cannot read the kernel journal — run as root for GPU init events and ACPI overrides"
else
  resets=$(grep -c "amdgpu .*resetting" <<<"$klog" || true)
  inits=$(grep -c "\[drm\] Initialized amdgpu" <<<"$klog" || true)
  say "GPU init events this boot: resets=${resets}  successful_inits=${inits}"
fi

# --- ACPI overrides ----------------------------------------------------------
# Every table the kernel installs prints its header line at boot.  Read it from
# the journal: the 256 KB printk buffer has wrapped long before a long uptime ends.
echo
say "ACPI overrides from /boot/acpi_override.img:"
acpi_log=$(grep -E '^ACPI: SSDT 0x[0-9A-Fa-f]+ .*(GFXALT|TbtOnPCH)' <<<"$klog")
if [[ -z "$klog" ]]; then
  warn "Kernel journal not readable — ACPI overrides not checked"
elif grep -q 'GFXALT' <<<"$acpi_log"; then
  ok  "GFXALT SSDT loaded (GPU _PR3/_DSM stubs)"
else
  warn "GFXALT SSDT not in this boot's log — layer 1 is not active"
fi
if grep -q 'TbtOnPCH 00001001' <<<"$acpi_log"; then
  ok  "Thunderbolt resume patch active (TbtOnPCH OEM revision 0x1001)"
  tbt_rec=$(cat /var/lib/t2-pci-amdgpu/TbtOnPCH.bios 2>/dev/null)
  tbt_now=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
  if [[ -n "$tbt_rec" && "$tbt_rec" != "$tbt_now" ]]; then
    warn "  Patched on firmware '$tbt_rec', running '$tbt_now' — re-run install.sh"
  fi
elif grep -q 'TbtOnPCH' <<<"$acpi_log"; then
  warn "Apple's own TbtOnPCH is live — each S3 resume spends ~9 s in its _PS0 waits"
  warn "  Re-run install.sh and reboot to load the patched copy."
fi

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

# --- GPU power and HDMI audio -------------------------------------------------
echo
say "GPU power state:"
card=$(amd_nodes card); card=${card%% *}
gpu_dev=""
[[ -n "$card" ]] && gpu_dev=$(readlink -f "/sys/class/drm/${card##*/}/device")
if [[ -z "$gpu_dev" ]]; then
  warn "No AMD card node — GPU power state not available"
else
  dpm=$(cat "$gpu_dev/power_dpm_force_performance_level" 2>/dev/null)
  if [[ "$dpm" == low ]]; then
    ok  "DPM level: low (pinned by 99-amdgpu-t2.rules)"
  else
    warn "DPM level: ${dpm:-unknown} — 99-amdgpu-t2.rules pins it to low"
  fi
  clocks=""
  for f in sclk mclk; do
    cur=$(grep -m1 '\*' "$gpu_dev/pp_dpm_$f" 2>/dev/null | awk '{print $2}')
    clocks+=" $f=${cur:-?}"
  done
  temps=""
  for l in "$gpu_dev"/hwmon/hwmon*/temp*_label; do
    [[ -e "$l" ]] || continue
    t=$(cat "${l%_label}_input" 2>/dev/null) || continue
    (( t > 0 )) && temps+=" $(cat "$l")=$(( t / 1000 ))°C"
  done
  pw=$(cat "$gpu_dev"/hwmon/hwmon*/power1_average 2>/dev/null | head -n1)
  printf "  %s%s  power=%s W\n" "${clocks# }" "$temps" "$(( ${pw:-0} / 1000000 ))"
fi

# On a boot where the warmfix reset the GPU, the reset wipes the HDMI audio
# function's config space and snd_hda_intel's probe of it fails: no HDMI/DP
# audio until the next boot with a good cold probe (known gap, see CLAUDE.md).
for aud in /sys/bus/pci/devices/*; do
  read -r ven 2>/dev/null < "$aud/vendor" || continue
  read -r cls 2>/dev/null < "$aud/class"  || continue
  [[ "$ven" == "0x1002" && "$cls" == 0x0403* ]] || continue
  if compgen -G "$aud/sound/card*" >/dev/null; then
    ok  "HDMI/DP audio: $(basename "$aud") has a sound card"
  else
    bar=$(od -A n -t x4 -j 16 -N 4 "$aud/config" 2>/dev/null | tr -d ' ')
    if [[ "$bar" == 00000000 ]]; then
      warn "HDMI/DP audio: none — $(basename "$aud") lost its config in the GPU reset (known gap after reset boots)"
    else
      warn "HDMI/DP audio: $(basename "$aud") has no sound card"
    fi
  fi
done

# --- Fan daemon ---------------------------------------------------------------
# A dead or restart-looping t2fanrd leaves the fan to the SMC's own curve,
# which ignores the CPU: loud at idle.  is-active alone hides a restart loop,
# hence fan1_manual and NRestarts.
echo
say "Fan daemon:"
smc=$(compgen -G '/sys/bus/acpi/devices/APP0001:*' | head -n1)
[[ -n "$smc" ]] || smc=$(compgen -G '/sys/devices/platform/applesmc.*' | head -n1)
fan_active=$(systemctl is-active t2fanrd.service 2>/dev/null)
fan_restarts=$(systemctl show -p NRestarts --value t2fanrd.service 2>/dev/null)
fan_exec=$(systemctl show -p ExecStart --value t2fanrd.service 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
if [[ "$fan_active" == active && "${fan_restarts:-0}" == 0 ]]; then
  ok  "t2fanrd: active, no restarts (${fan_exec:-unknown binary})"
else
  fail "t2fanrd: ${fan_active:-unknown}, NRestarts=${fan_restarts:-?} — see: journalctl -u t2fanrd -b"
fi
if [[ "$fan_exec" == /usr/local/bin/t2fanrd && -x /usr/bin/t2fanrd ]]; then
  warn "  Runs the bundled binary although the t2fanrd package is installed — re-run install.sh"
fi
if [[ -z "$smc" ]]; then
  fail "applesmc fan attributes not found"
else
  manual=$(cat "$smc/fan1_manual" 2>/dev/null)
  if [[ "$manual" == 1 ]]; then
    ok  "fan1_manual=1 (t2fanrd holds the fan)"
  else
    fail "fan1_manual=${manual:-?} — the SMC drives the fan on its own curve"
  fi
  printf "  fan1: %s RPM (target %s, range %s–%s)\n" \
    "$(cat "$smc/fan1_input" 2>/dev/null)" "$(cat "$smc/fan1_output" 2>/dev/null)" \
    "$(cat "$smc/fan1_min" 2>/dev/null)" "$(cat "$smc/fan1_max" 2>/dev/null)"
  # The daemon reads fan1_max once at start and never exceeds it; cold-boot
  # starts have read 2700 although the SMC runs the fan to ~3600.
  logged_max=$(journalctl -u t2fanrd -b -o cat --no-pager 2>/dev/null | sed -n 's/.*max_speed: \([0-9]*\).*/\1/p' | tail -n1)
  [[ -n "$logged_max" ]] && echo "  daemon's speed limit (from its last start): $logged_max RPM"
fi

# --- CPU power profile --------------------------------------------------------
echo
say "CPU power profile:"
if command -v tuned-adm >/dev/null; then
  echo "  tuned: $(tuned-adm active 2>/dev/null | sed 's/^Current active profile: //')"
elif command -v powerprofilesctl >/dev/null; then
  echo "  power profile: $(powerprofilesctl get 2>/dev/null)"
fi
echo "  cpu0: governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" \
     "epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"

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
