#!/usr/bin/env bash
# Builds Claudometer.app *with the desktop widget* using Xcode (no signing team needed),
# installs it to /Applications and launches it.
#   scripts/build-xcode.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodegen generate >/dev/null
xcodebuild -project Claudometer.xcodeproj -scheme Claudometer -configuration Release \
    -derivedDataPath build/xcode build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP="build/xcode/Build/Products/Release/Claudometer.app"
[ -d "$APP/Contents/PlugIns/ClaudometerWidget.appex" ] || { echo "Build failed"; exit 1; }

pkill -x Claudometer 2>/dev/null || true
pkill -f ClaudometerWidget 2>/dev/null || true
rm -rf /Applications/Claudometer.app
cp -R "$APP" /Applications/
open /Applications/Claudometer.app
echo "✓ Installed /Applications/Claudometer.app (with widget)"
