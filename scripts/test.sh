#!/usr/bin/env bash
# Runs the unit tests from a throwaway build directory outside the repo. With only the
# Command Line Tools, reusing a build directory loses the swift-testing macro plugin
# ("TestingMacros not found").
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
swift test --build-path "$BUILD_DIR" "$@"
