#!/bin/zsh
set -eu
cd "${0:A:h:h}"
watch_checks_dir=$(mktemp -d /tmp/berms-watch-checks.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 6 \
    Berms/WatchRideProtocol.swift \
    BermsWatchExtension/WatchRideTransport.swift \
    BermsWatchExtension/WatchDashboardModel.swift \
    BermsTests/WatchLifecycleChecks.swift \
    -o "$watch_checks_dir/watch-checks"
"$watch_checks_dir/watch-checks"
