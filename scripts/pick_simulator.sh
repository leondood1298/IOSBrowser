#!/usr/bin/env bash
# Prints the UDID of the best available iPad simulator: newest iOS runtime, preferring
# iPad Pro 13-inch. The chosen device name goes to stderr for the log.
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, re, sys

devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not match:
        continue
    version = tuple(int(part or 0) for part in match.groups())
    for device in entries:
        name = device["name"]
        if not name.startswith("iPad"):
            continue
        preference = 2 if "iPad Pro 13" in name else 1 if "iPad Pro" in name else 0
        score = (version, preference)
        if best is None or score > best[0]:
            best = (score, device["udid"], name, runtime)
if best is None:
    sys.exit("No iPad simulator is available")
print(best[1])
print("Using %s (%s)" % (best[2], best[3]), file=sys.stderr)
'
