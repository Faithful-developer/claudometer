#!/usr/bin/env bash
# Installs (or updates) Claudometer from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/Faithful-developer/claudometer/main/scripts/install.sh | bash
#
# Downloads the DMG, checks it against the SHA-256 GitHub publishes for it, and copies the app
# to /Applications. Files fetched this way carry no quarantine flag, so macOS doesn't ask for
# "Open Anyway" on first launch.
#
# Environment (mostly for testing):
#   CLAUDOMETER_INSTALL_DIR   install somewhere other than /Applications
#   CLAUDOMETER_NO_OPEN=1     don't launch the app afterwards
#   CLAUDOMETER_EXPECT_SHA256 check against this checksum instead of GitHub's (tests the abort path)
set -euo pipefail

REPO="Faithful-developer/claudometer"
BUNDLE_ID="dev.claudometer.app"
DEST="${CLAUDOMETER_INSTALL_DIR:-/Applications}"

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Claudometer is a macOS app."
[[ -d "$DEST" ]] || fail "$DEST doesn't exist."
[[ -w "$DEST" ]] || fail "Can't write to $DEST. Run this from an administrator account, or set CLAUDOMETER_INSTALL_DIR to a folder you own (e.g. ~/Applications)."

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
    hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

say "▸ Finding the latest release"
RELEASE="$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest")" \
    || fail "Couldn't reach GitHub."
# The .dmg asset's download URL, checksum and the release tag, without needing jq.
read -r TAG URL DIGEST < <(/usr/bin/python3 -c '
import json, sys
r = json.load(sys.stdin)
dmg = next((a for a in r.get("assets", []) if a.get("name", "").endswith(".dmg")), {})
print(r.get("tag_name", "-"), dmg.get("browser_download_url", "-"), dmg.get("digest") or "-")
' <<<"$RELEASE") || fail "Couldn't read the release information."
[[ "$URL" != "-" ]] || fail "The latest release ($TAG) has no DMG."
EXPECTED="${CLAUDOMETER_EXPECT_SHA256:-${DIGEST#sha256:}}"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] || fail "GitHub gave no checksum for the DMG, so it can't be verified."

say "▸ Downloading Claudometer ${TAG#v}"
curl -fL --progress-bar -o "$WORK/Claudometer.dmg" "$URL" || fail "The download failed."

say "▸ Verifying"
ACTUAL="$(shasum -a 256 "$WORK/Claudometer.dmg" | awk '{print $1}')"
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED")" == "$ACTUAL" ]] \
    || fail "The download doesn't match the release checksum. Nothing was installed."

mkdir -p "$MOUNT"
hdiutil attach "$WORK/Claudometer.dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet \
    || fail "Couldn't open the DMG."
[[ -d "$MOUNT/Claudometer.app" ]] || fail "The DMG doesn't contain Claudometer.app."
codesign --verify --deep "$MOUNT/Claudometer.app" 2>/dev/null || fail "The app's signature is broken."

# Quit only the copy being replaced, not one running from somewhere else.
TARGET_BIN="$DEST/Claudometer.app/Contents/MacOS/Claudometer"
if pgrep -fq "$TARGET_BIN"; then
    say "▸ Quitting the running Claudometer"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do pgrep -fq "$TARGET_BIN" || break; sleep 0.2; done
    pkill -f "$TARGET_BIN" 2>/dev/null || true
fi

say "▸ Installing to $DEST"
rm -rf "$DEST/Claudometer.app"
# No extended attributes: no quarantine flag, so no Gatekeeper prompt on first launch.
ditto --noextattr --noqtn "$MOUNT/Claudometer.app" "$DEST/Claudometer.app"

if [[ -z "${CLAUDOMETER_NO_OPEN:-}" ]]; then
    open "$DEST/Claudometer.app"
fi
say "✓ Claudometer ${TAG#v} is installed. Look for it in the menu bar."
say "  Add the widget: right-click the desktop → Edit Widgets… → search \"Claudometer\"."
