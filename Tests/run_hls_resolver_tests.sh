#!/bin/bash
set -euo pipefail
kit_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/mpv-hls-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
# 直接编译生产解析器，在 macOS 运行不依赖 UIKit/MPV 的网络并发回归。
mkdir -p "$test_dir/Sources/MPVPlayerKit" "$test_dir/Tests/MPVPlayerKitTests"
cp "$kit_root/Sources/MPVPlayerKit/MPVHLSMasterResolver.swift" "$test_dir/Sources/MPVPlayerKit/"
cp "$kit_root/Tests/MPVPlayerKitTests/MPVHLSMasterResolverTests.swift" "$test_dir/Tests/MPVPlayerKitTests/"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HLSResolverRegression", targets: [
    .target(name: "MPVPlayerKit"),
    .testTarget(name: "MPVPlayerKitTests", dependencies: ["MPVPlayerKit"])
])
SWIFT
xcrun swift test --package-path "$test_dir" --jobs 2
