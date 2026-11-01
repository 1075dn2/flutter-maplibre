#!/usr/bin/env bash
set -euo pipefail
# macOS Swift toolchain only. Does not exercise MapLibre delegate integration.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Sources/ScopedPolicy" "$TMP/Tests/ScopedPolicyTests"
cp "$ROOT/packages/maplibre_ios/ios/maplibre_ios/Sources/maplibre_ios/ScopedRequestPolicy.swift" "$TMP/Sources/ScopedPolicy/"
cp "$ROOT/tool/ios-network-tests/ScopedRequestPolicyTests.swift" "$TMP/Tests/ScopedPolicyTests/"
cat > "$TMP/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ScopedPolicy", targets: [.target(name: "ScopedPolicy"), .testTarget(name: "ScopedPolicyTests", dependencies: ["ScopedPolicy"])])
PACKAGE
cd "$TMP"
swift test
