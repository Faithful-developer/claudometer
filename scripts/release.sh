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
# Designed window (background, icon layout, volume icon); asks once to let Terminal control Finder.
scripts/make-dmg.sh "$APP" "$DMG" "Claudometer $VERSION"

echo "▸ Publishing $TAG"
git tag -a "$TAG" -m "Claudometer $VERSION"
git push origin main "$TAG"
INSTALL_NOTE=$'\n\n### Install\n- **Already have Claudometer (newer than 0.2.0)?** Click **Install Update** in its menu.\n- **Homebrew:** `brew install --cask faithful-developer/tap/claudometer`\n- **Terminal:** `curl -fsSL https://raw.githubusercontent.com/Faithful-developer/claudometer/main/scripts/install.sh | bash`\n- **DMG:** open it and drag **Claudometer** to **Applications**. The app is not notarized, so the first launch is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**.\n\nAdd the widget: right-click the desktop → **Edit Widgets…** → search "Claudometer".'
gh release create "$TAG" "$DMG" --title "Claudometer $VERSION" --notes "${NOTES:-Claudometer $VERSION}${INSTALL_NOTE}"
echo "✓ Released $TAG"

# Homebrew: point the cask in Faithful-developer/homebrew-tap at this release. A failure
# here doesn't undo the release; it says how to do it by hand.
echo "▸ Updating the Homebrew cask"
bump_cask() {
    local tap sha
    tap="$(mktemp -d)"
    trap 'rm -rf "$tap"' RETURN
    sha="$(gh release view "$TAG" --json assets -q '.assets[] | select(.name | endswith(".dmg")) | .digest' | sed 's/^sha256://')"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    gh repo clone Faithful-developer/homebrew-tap "$tap" -- --quiet || return 1
    sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$tap/Casks/claudometer.rb"
    git -C "$tap" commit -qam "claudometer $VERSION" || return 1
    git -C "$tap" push -q origin HEAD || return 1
}
if bump_cask; then
    echo "✓ Cask updated to $VERSION"
else
    echo "⚠︎ Couldn't update the cask. Edit version and sha256 in Faithful-developer/homebrew-tap/Casks/claudometer.rb by hand."
fi
