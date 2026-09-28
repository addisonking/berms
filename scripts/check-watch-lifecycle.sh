#!/bin/zsh
set -eu
cd "${0:A:h:h}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

watch_checks_dir=$(mktemp -d /tmp/berms-watch-checks.XXXXXX)
trap 'rm -rf "$watch_checks_dir"' EXIT
xcrun swiftc -swift-version 6 \
    Berms/Connectivity/WatchRideProtocol.swift \
    BermsWatchExtension/Connectivity/WatchRideTransport.swift \
    BermsWatchExtension/Model/WatchDashboardModel.swift \
    BermsTests/WatchLifecycleChecks.swift \
    -o "$watch_checks_dir/watch-checks"
"$watch_checks_dir/watch-checks"
