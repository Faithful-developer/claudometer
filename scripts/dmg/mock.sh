#!/usr/bin/env bash
# Review aid: composites the real icons and Finder-style names over the DMG art, once with
# black names (Light appearance) and once with white (Dark), into scripts/dmg/mock-*.png.
# Finder windows can't be screenshotted without Screen Recording permission; this can.
# Positions mirror scripts/make-dmg.sh. Needs Google Chrome; run render-background.sh first.
set -euo pipefail
cd "$(dirname "$0")/../.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ICONS=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sips -s format png -Z 256 Resources/AppIcon.icns --out "$WORK/app.png" >/dev/null
sips -s format png -Z 256 "$ICONS/ApplicationsFolderIcon.icns" --out "$WORK/folder.png" >/dev/null
sips -s format png -Z 64 "$ICONS/AliasBadgeIcon.icns" --out "$WORK/alias.png" >/dev/null
cp scripts/dmg/preview@2x.png "$WORK/bg.png"

for mode in light dark; do
    [[ $mode == light ]] && ink="#000" || ink="#fff"
    cat > "$WORK/$mode.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><style>
  body { margin: 0; width: 660px; height: 400px; position: relative; overflow: hidden;
         background: url(bg.png) 0 0 / 660px 400px; font: 13px -apple-system, sans-serif; }
  img { position: absolute; width: 112px; height: 112px; }
  .name { position: absolute; width: 160px; text-align: center; color: $ink; line-height: 16px; }
</style></head><body>
  <img src="app.png" style="left: 114px; top: 144px">
  <img src="folder.png" style="left: 434px; top: 144px">
  <img src="alias.png" style="left: 430px; top: 222px; width: 36px; height: 36px">
  <div class="name" style="left: 90px; top: 266px">Claudometer</div>
  <div class="name" style="left: 410px; top: 266px">Applications</div>
</body></html>
HTML
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb \
        --allow-file-access-from-files --window-size=660,400 --force-device-scale-factor=2 \
        --virtual-time-budget=1000 --screenshot="$WORK/$mode.png" "file://$WORK/$mode.html" >/dev/null 2>&1
    cp "$WORK/$mode.png" "scripts/dmg/mock-$mode.png"
done
echo "✓ scripts/dmg/mock-light.png, scripts/dmg/mock-dark.png"
