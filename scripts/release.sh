#!/usr/bin/env bash
# Publishes a GitHub release: app + widget (Xcode build) packaged as a DMG.
#   scripts/release.sh 0.2.0 ["Release notes"]
# Bump the version on every release: the app's update check compares it with the latest tag.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-}"
TAG="v$VERSION"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }

echo "▸ Building $VERSION"
BUILD_NUMBER="$(git rev-list --count HEAD)"
xcodegen generate >/dev/null
xcodebuild -project Claudometer.xcodeproj -scheme Claudometer -configuration Release \
    -derivedDataPath build/xcode MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="build/xcode/Build/Products/Release/Claudometer.app"
[[ -d "$APP/Contents/PlugIns/ClaudometerWidget.appex" ]] || { echo "Build failed"; exit 1; }
[[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] || { echo "Version mismatch"; exit 1; }

echo "▸ Packaging"
DMG="build/Claudometer-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Claudometer $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "▸ Publishing $TAG"
git tag -a "$TAG" -m "Claudometer $VERSION"
git push origin main "$TAG"
INSTALL_NOTE=$'\n\n### Install\n1. Open the DMG and drag **Claudometer** to **Applications**.\n2. The app is not notarized, so the first launch is blocked. Open **System Settings → Privacy & Security** and click **Open Anyway** (or run `xattr -dr com.apple.quarantine /Applications/Claudometer.app`).\n3. Add the widget: right-click the desktop → **Edit Widgets…** → search "Claudometer".'
gh release create "$TAG" "$DMG" --title "Claudometer $VERSION" --notes "${NOTES:-Claudometer $VERSION}${INSTALL_NOTE}"
echo "✓ Released $TAG"
