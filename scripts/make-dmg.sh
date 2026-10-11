#!/usr/bin/env bash
# Packages an app into a designed DMG: background art, icon layout and a custom volume icon.
#
#   scripts/make-dmg.sh build/Claudometer.app build/Claudometer-0.2.0.dmg "Claudometer 0.2.0"
#
# The layout is written by Finder (AppleScript), so the first run asks to let Terminal
# control Finder. The art is Resources/DMG/background.tiff (scripts/dmg/render-background.sh);
# the icon positions below must match its label plates.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: scripts/make-dmg.sh <app> <out.dmg> <volume name>}"
DMG="${2:?usage: scripts/make-dmg.sh <app> <out.dmg> <volume name>}"
VOLNAME="${3:-Claudometer}"
APP_NAME="$(basename "$APP")"

# Window content size and icon centres, in points (see scripts/dmg/background.html).
WIDTH=660
HEIGHT=400
APP_X=170;  APP_Y=200
LINK_X=490; LINK_Y=200
ICON_SIZE=112

WORK="$(mktemp -d)"
DEVICE=""
cleanup() {
    [[ -n "$DEVICE" ]] && hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "▸ Staging"
STAGING="$WORK/staging"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp Resources/DMG/background.tiff "$STAGING/.background/background.tiff"
# Show "Claudometer", not "Claudometer.app", under the icon.
command -v SetFile >/dev/null && SetFile -a E "$STAGING/$APP_NAME" || true

echo "▸ Creating writable image"
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))
hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ -format UDRW \
    -size "${SIZE_MB}m" -ov "$WORK/rw.dmg" >/dev/null
ATTACH="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen)"
DEVICE="$(echo "$ATTACH" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="$(echo "$ATTACH" | grep -E '/Volumes/' | sed -E 's#.*(/Volumes/.*)#\1#' | head -1)"
[[ -d "$MOUNT" ]] || { echo "Couldn't mount the image"; exit 1; }

echo "▸ Laying out the window (Finder)"
# Give Finder a moment to see the new volume.
sleep 1
osascript <<APPLESCRIPT
tell application "Finder"
    set theDisk to folder (POSIX file "$MOUNT" as alias)
    open theDisk
    set theWindow to container window of theDisk
    -- The path bar follows a global Finder setting; hide it here, put it back below.
    set hadPathbar to pathbar visible of theWindow
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set pathbar visible of theWindow to false
    -- Bounds include the title bar (32 pt on macOS 26); corrected below if it differs.
    set bounds of theWindow to {200, 120, 200 + $WIDTH, 120 + $HEIGHT + 32}
    set opts to icon view options of theWindow
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set shows icon preview of opts to false
    set background picture of opts to file ".background:background.tiff" of theDisk
    set position of item "$APP_NAME" of theDisk to {$APP_X, $APP_Y}
    set position of item "Applications" of theDisk to {$LINK_X, $LINK_Y}
end tell

-- Make the content area exactly match the art. Needs Accessibility for System Events;
-- without it the 32 pt default stays.
try
    delay 0.5
    tell application "System Events" to tell process "Finder"
        set contentHeight to item 2 of (get size of scroll area 1 of UI element 1 of splitter group 1 of window 1)
    end tell
    if contentHeight is not $HEIGHT then
        tell application "Finder"
            set {l, t, r, b} to bounds of theWindow
            set bounds of theWindow to {l, t, r, b + ($HEIGHT - contentHeight)}
        end tell
    end if
end try

tell application "Finder"
    update theDisk without registering applications
    delay 1
    close theWindow
    -- Reopen once so Finder writes the final .DS_Store.
    open theDisk
    delay 1
    close container window of theDisk
    if hadPathbar then
        -- Restore the user's path bar setting on a throwaway window.
        set tmp to make new Finder window
        set pathbar visible of tmp to true
        close tmp
    end if
end tell
APPLESCRIPT

# Wait for Finder to write .DS_Store.
for _ in {1..10}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "$MOUNT/.DS_Store" ]] || echo "  (warning: Finder didn't write the layout)"
# Custom volume icon. After the Finder step, which drops it.
if [[ -f Resources/AppIcon.icns ]] && command -v SetFile >/dev/null; then
    cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
fi

rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync

hdiutil detach "$DEVICE" >/dev/null
DEVICE=""

echo "▸ Compressing"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "✓ Packaged $DMG"
