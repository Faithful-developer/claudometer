#!/usr/bin/env bash
# Renders scripts/dmg/background.html to Resources/DMG/background.tiff (1x + 2x in one TIFF,
# so Finder picks the sharp one on Retina). Needs Google Chrome; run after editing the art.
set -euo pipefail
cd "$(dirname "$0")/../.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
for scale in 1 2; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb \
        --window-size=660,400 --force-device-scale-factor="$scale" \
        --virtual-time-budget=1000 --screenshot="$OUT/bg@${scale}x.png" \
        "file://$PWD/scripts/dmg/background.html" >/dev/null 2>&1
done
mkdir -p Resources/DMG
tiffutil -cathidpicheck "$OUT/bg@1x.png" "$OUT/bg@2x.png" -out Resources/DMG/background.tiff >/dev/null
# Keep a preview for review (not used by the build).
cp "$OUT/bg@2x.png" scripts/dmg/preview@2x.png
echo "✓ Resources/DMG/background.tiff"
