#!/usr/bin/env bash
# Builds Claudometer.app from the Swift package (no Xcode needed).
#
#   scripts/build-app.sh            # release build into ./build/Claudometer.app
#   scripts/build-app.sh --install  # also copy to /Applications and launch
#   scripts/build-app.sh --dmg      # also package build/Claudometer-<version>.dmg
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   # real signing
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-dev.claudometer.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
APP="build/Claudometer.app"

echo "▸ Building release binary"
# Separate build path: the universal build's cache breaks `swift test` in the default one.
BUILD_PATH=".build/app"
if swift build -c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH" >/dev/null 2>&1; then
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH" --show-bin-path)"
else
    echo "  (universal build unavailable, building for $(uname -m))"
    swift build -c release --build-path "$BUILD_PATH"
    BIN_DIR="$(swift build -c release --build-path "$BUILD_PATH" --show-bin-path)"
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Claudometer" "$APP/Contents/MacOS/Claudometer"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claudometer</string>
    <key>CFBundleDisplayName</key><string>Claudometer</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Claudometer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>Claudometer</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key><array><string>claudometer</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "▸ Signing (${SIGN_IDENTITY})"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Claudometer 2>/dev/null || true
    rm -rf /Applications/Claudometer.app
    cp -R "$APP" /Applications/
    open /Applications/Claudometer.app
    echo "✓ Installed to /Applications and launched"
fi

if [[ "${1:-}" == "--dmg" ]]; then
    DMG="build/Claudometer-${VERSION}.dmg"
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    rm -f "$DMG"
    hdiutil create -volname Claudometer -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGING"
    echo "✓ Packaged $DMG"
    # Notarize (needs a Developer ID identity):
    #   xcrun notarytool submit "$DMG" --keychain-profile <profile> --wait && xcrun stapler staple "$DMG"
fi
