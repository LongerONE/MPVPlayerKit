#!/bin/bash
set -euo pipefail
kit_root="$(cd "$(dirname "$0")/.." && pwd)"
# 指定已安装的模拟器，例如 MPV_TEST_DESTINATION='platform=iOS Simulator,id=...'
test_destination="${MPV_TEST_DESTINATION:?请设置 MPV_TEST_DESTINATION 为已安装的 iOS 模拟器}"
derived_data="${MPV_TEST_DERIVED_DATA:-/tmp/mpv-playerkit-tests-derived}"
xcodebuild -project "$kit_root/Demo/MPVPlayerKitDemo.xcodeproj" \
    -scheme MPVPlayerKitDemo -configuration Debug -destination "$test_destination" \
    -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO test "$@"
