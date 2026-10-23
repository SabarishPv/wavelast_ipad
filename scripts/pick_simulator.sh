#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Prints the UDID of an available iPad simulator on the newest installed iOS
# runtime. Runner images change their device list over time, so the workflow
# asks instead of hard-coding a model name.
set -euo pipefail
xcrun simctl list devices available --json | python3 -I -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
def ver(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
preferred = ["iPad Pro 13-inch", "iPad Air 13-inch", "iPad Pro 11-inch", "iPad Air 11-inch", "iPad (", "iPad mini"]
best = None
for runtime, devices in data.items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if not d["name"].startswith("iPad"):
            continue
        rank = next((i for i, p in enumerate(preferred) if d["name"].startswith(p)), len(preferred))
        key = (ver(runtime), -rank)
        if best is None or key > best[0]:
            best = (key, d["udid"], d["name"], runtime)
if not best:
    sys.exit("No available iPad simulator found")
print(best[1])
print(f"Selected {best[2]} ({best[3]})", file=sys.stderr)
'
