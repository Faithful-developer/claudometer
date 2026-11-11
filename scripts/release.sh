#!/usr/bin/env bash
# Publishes a GitHub release: app + widget (Xcode build) packaged as a DMG.
#   scripts/release.sh 0.2.0 ["Release notes"]
#   scripts/release.sh 0.2.0 --dry-run     # test, build and package only; publishes nothing
# Bump MARKETING_VERSION in project.yml first (and commit): the app's update check compares
# it with the latest release, and this script refuses a version that differs from it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="${1:?usage: scripts/release.sh <version> [notes] [--dry-run]}"
shift
DRY_RUN=false
NOTES=""
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then DRY_RUN=true; else NOTES="$arg"; fi
done
TAG="v$VERSION"

PROJECT_VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml)"
[[ "$PROJECT_VERSION" == "$VERSION" ]] || { echo "project.yml says $PROJECT_VERSION, not $VERSION. Bump it first."; exit 1; }
if ! $DRY_RUN; then
    [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
    [[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main."; exit 1; }
    git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }
fi

mkdir -p build
echo "▸ Testing"
scripts/test.sh >build/test.log 2>&1 || { tail -40 build/test.log; echo "Tests failed (build/test.log)"; exit 1; }

echo "▸ Building $VERSION"
BUILD_NUMBER="$(git rev-list --count HEAD)"
xcodegen generate >/dev/null
LOG="build/xcodebuild.log"
if ! xcodebuild -project Claudometer.xcodeproj -scheme Claudometer -configuration Release \
    -derivedDataPath build/xcode MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 || tail -20 "$LOG"
    echo "Build failed ($LOG)"
    exit 1
fi
APP="build/xcode/Build/Products/Release/Claudometer.app"
[[ -d "$APP/Contents/PlugIns/ClaudometerWidget.appex" ]] || { echo "Build has no widget"; exit 1; }
[[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] || { echo "Version mismatch"; exit 1; }

echo "▸ Packaging"
DMG="build/Claudometer-$VERSION.dmg"
# Designed window (background, icon layout, volume icon); asks once to let Terminal control Finder.
scripts/make-dmg.sh "$APP" "$DMG" "Claudometer $VERSION"

if $DRY_RUN; then
    echo "✓ Dry run: $DMG is ready. Nothing was tagged, pushed or published."
    exit 0
fi

# A draft first, so a failed upload leaves nothing public: installed apps only see a
# published release, and the tag is pushed once the draft exists.
echo "▸ Publishing $TAG"
INSTALL_NOTE=$'\n\n### Install\n- **Already have Claudometer (newer than 0.2.0)?** Click **Install Update** in its menu.\n- **Homebrew:** `brew install --cask faithful-developer/tap/claudometer`\n- **Terminal:** `curl -fsSL https://raw.githubusercontent.com/Faithful-developer/claudometer/main/scripts/install.sh | bash`\n- **DMG:** open it and drag **Claudometer** to **Applications**. The app is not notarized, so the first launch is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**.\n\nAdd the widget: right-click the desktop → **Edit Widgets…** → search "Claudometer".'
git push origin main
gh release create "$TAG" "$DMG" --draft --target "$(git rev-parse HEAD)" \
    --title "Claudometer $VERSION" --notes "${NOTES:-Claudometer $VERSION}${INSTALL_NOTE}"
git tag -a "$TAG" -m "Claudometer $VERSION"
git push origin "$TAG"
gh release edit "$TAG" --draft=false --latest
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
