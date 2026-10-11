#!/usr/bin/env bash
# Runs the unit tests from a throwaway build directory outside the repo. With only the
# Command Line Tools, reusing a build directory loses the swift-testing macro plugin
# ("TestingMacros not found"), and newer Command Line Tools don't find it at all unless
# its folder is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
FLAGS=()
PLUGINS="$(xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins/testing"
[[ -d "$PLUGINS" ]] && FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
swift test --build-path "$BUILD_DIR" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
