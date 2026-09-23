#!/bin/zsh
set -eu
set -o pipefail
cd "${0:A:h:h}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ -n "${BERMS_TEST_DESTINATION:-}" ]]; then
    destination="$BERMS_TEST_DESTINATION"
else
    devices=$(xcrun simctl list devices available -j) || {
        echo "could not list simulators; is Xcode installed and DEVELOPER_DIR set?" >&2
        exit 1
    }
    # Newest iOS runtime first, then the alphabetically last iPhone name.
    udid=$(printf '%s' "$devices" | python3 -c '
import json, sys

best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(part) for part in runtime.split("-") if part.isdigit())
    for device in devices:
        if not device["name"].startswith("iPhone"):
            continue
        candidate = (version, device["name"])
        if best is None or candidate > best[0]:
            best = (candidate, device["udid"])
print(best[1] if best else "")
')
    if [[ -z "$udid" ]]; then
        echo "no available iPhone simulator found" >&2
        exit 1
    fi
    destination="platform=iOS Simulator,id=$udid"
fi

xcodebuild test \
    -project Berms.xcodeproj \
    -scheme Berms \
    -destination "$destination" \
    -derivedDataPath /tmp/berms-test-build \
    "$@"
