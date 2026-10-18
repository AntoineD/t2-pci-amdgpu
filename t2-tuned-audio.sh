#!/usr/bin/env bash
# t2-tuned-audio.sh [PROFILE...] — what tuned does to snd_hda_intel's
# power_save_controller under PROFILE (default: the active profile).
#
# Prints one line, "STATE FILE":
#   on   FILE  tuned writes Y; FILE is where the deciding unit or value comes from
#   off  FILE  tuned writes N (0)
#   bad  FILE  FILE sets a value the kernel rejects, so tuned's write fails
#   none -     no tuned audio instance gets snd_hda_intel
# Exits 1, printing nothing, when tuned's profiles cannot be loaded.
#
# This replays tuned's own rules with tuned's own code (tuned 2.28):
#   - Loader.load() resolves includes, profile_dirs and variables, and the
#     Merger merges units by section name (replace=, drop=, enabled=).
#   - Each enabled unit of type audio is a separate plugin instance, sorted
#     by priority (stable, so file order breaks ties).  cpuinfo_regex and
#     uname_regex can skip one.
#   - The audio plugin hands each module to the first instance whose
#     devices= matches it; later instances get nothing.  devices_udev_regex
#     matches nothing (the plugin has no udev device objects).
#   - reset_controller defaults to true.  tuned maps Y/YES/T/TRUE/N/NO/F/FALSE
#     to 1/0 and passes anything else through to the kernel's kstrtobool.
# Called by amdgpu-check.sh (from its own directory) and by install.sh.
set -Eeuo pipefail

python3 -I - "$@" 2>/dev/null <<'EOF'
import os, re, sys
import tuned.consts as c
import tuned.profiles as p
import tuned.profiles.variables as v
import tuned.utils.global_config as gc
from tuned.hardware.device_matcher import DeviceMatcher

DEVICE = "snd_hda_intel"
current, source, owner = [None], {}, {}

class Locator(p.Locator):                   # remembers the file it resolves
    def get_config(self, profile_name, skip_files=None):
        current[0] = super().get_config(profile_name, skip_files)
        return current[0]

class Factory(p.Factory):                   # tags each profile with that file
    def create(self, name, config):
        prof = super().create(name, config)
        source[id(prof)] = current[0]
        return prof

class Merger(p.Merger):
    # Before merging (the merge mutates the units), follow which file last
    # decided reset_controller for each unit name: the one that set or
    # dropped it, else the one that defined the unit.
    def merge(self, configs):
        for prof in configs:
            f = source[id(prof)]
            for name, unit in prof.units.items():
                if unit.replace or name not in owner:
                    owner[name] = f
                elif unit.drop and "reset_controller" in unit.drop:
                    owner[name] = f
                if "reset_controller" in unit.options:
                    owner[name] = f
        return super().merge(configs)

g = gc.GlobalConfig()
names = sys.argv[1:]
if not names:
    with open(c.ACTIVE_PROFILE_FILE) as fh:
        names = fh.read().split()
if not names:
    print("none -")
    sys.exit(0)
loader = p.Loader(Locator(g.get_list(c.CFG_PROFILE_DIRS, c.CFG_DEF_PROFILE_DIRS)),
                  Factory(), Merger(), g, v.Variables())
merged = loader.load(names)

def regex_ok(rx, text):
    return rx is None or re.search(rx, text(), re.MULTILINE) is not None
cpuinfo = lambda: g.get(c.CFG_CPUINFO_STRING) or open("/proc/cpuinfo").read()
uname = lambda: g.get(c.CFG_UNAME_STRING) or " ".join(os.uname())
def_prio = g.get_int(c.CFG_DEFAULT_INSTANCE_PRIORITY, c.CFG_DEF_DEFAULT_INSTANCE_PRIORITY)

units = [(name, u) for name, u in merged.units.items()
         if u.enabled and u.type == "audio"
         and regex_ok(u.cpuinfo_regex, cpuinfo) and regex_ok(u.uname_regex, uname)]
units.sort(key=lambda nu: def_prio if nu[1].priority is None else int(nu[1].priority))
matcher = DeviceMatcher()
for name, u in units:
    if u.devices_udev_regex is not None or not matcher.match(u.devices, DEVICE):
        continue
    val = u.options.get("reset_controller", True)
    if val is True:
        state = "on"
    else:
        s = str(val).strip()
        s = {"Y": "1", "YES": "1", "T": "1", "TRUE": "1",
             "N": "0", "NO": "0", "F": "0", "FALSE": "0"}.get(s.upper(), s)
        # kstrtobool: first character, and for "o" the second one.
        k = s[:2].lower()
        if k[:1] in ("y", "t", "1") or k == "on":
            state = "on"
        elif k[:1] in ("n", "f", "0") or k == "of":
            state = "off"
        else:
            state = "bad"
    print(state, owner.get(name) or "-")
    break
else:
    print("none -")
EOF
