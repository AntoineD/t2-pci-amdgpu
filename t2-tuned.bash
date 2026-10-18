# t2-tuned.bash — tuned override helpers shared by install.sh and uninstall.sh.
# Sourced, not run; needs SRC_DIR, DRY_RUN, say and warn from the caller.
# See t2-tuned-hda.conf.in for why the overrides exist.

TUNED_TEMPLATE="${SRC_DIR}/t2-tuned-hda.conf.in"
# The template's first line marks the files we generated; it is the one copy.
TUNED_MARK="$(head -n1 -- "$TUNED_TEMPLATE")"
# Used by the scripts that source this file.
# shellcheck disable=SC2034
TUNED_STOCK_DIR=/usr/lib/tuned/profiles
# shellcheck disable=SC2034
TUNED_ETC_DIR=/etc/tuned/profiles
# shellcheck disable=SC2034
HDA_PSC=/sys/module/snd_hda_intel/parameters/power_save_controller

tuned_is_ours() {    # tuned_is_ours FILE
  local first=""
  [[ -f "$1" ]] && read -r first < "$1"
  [[ "$first" == "$TUNED_MARK" ]]
}

tuned_has_audio() {  # tuned_has_audio FILE — has an [audio] unit
  grep -qsE '^[[:space:]]*\[audio\][[:space:]]*$' "$1"
}

tuned_generate() {   # tuned_generate PROFILE — the override for PROFILE, on stdout
  sed "s/@PROFILE@/$1/g" "$TUNED_TEMPLATE"
}

# tuned_settings — a profile's sections and settings, without comments, blank
# lines or the summary, so a template change that only rewords those does not
# count as a user edit.
tuned_settings() {
  sed -E -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]+$//' -e '/^$/d' \
    -e '/^summary[[:space:]]*=/d' -- "$@"
}

# tuned_is_pristine FILE PROFILE — FILE (ours or a backup of ours) has the
# settings install.sh generates for PROFILE: nobody edited them.
tuned_is_pristine() {
  [[ "$(tuned_settings "$1")" == "$(tuned_generate "$2" | tuned_settings)" ]]
}

# tuned_reload — re-apply the active profile through tuned's D-Bus reload.
# Unlike "tuned-adm profile <same>" it keeps the profile selection mode.
# Never fails: callers run under set -e and a failed reload only warns.
tuned_reload() {
  systemctl is-active --quiet tuned.service || return 0
  if (( DRY_RUN )); then say "Would reload tuned's active profile"; return 0; fi
  if busctl call com.redhat.tuned /Tuned com.redhat.tuned.control reload 2>/dev/null \
       | grep -qx 'b true'; then
    say "tuned: active profile reloaded"
  else
    warn "tuned: reload failed — check: journalctl -u tuned -b"
  fi
  return 0
}
