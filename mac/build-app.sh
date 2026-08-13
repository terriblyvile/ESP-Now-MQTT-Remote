#!/bin/bash
# Builds "ESP-NOW Remote Flasher.app".
#
#   ./build-app.sh            release build into ./build
#   ./build-app.sh --open     ...and launch it
#
# The app is deliberately not sandboxed. It runs PlatformIO, opens /dev/cu.*
# devices and writes into a checkout you point it at, none of which a sandboxed
# app can do without entitlements this is not signed to carry.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ESP-NOW Remote Flasher"
BUNDLE_ID="io.github.terriblyvile.espnowflasher"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building (release)"
swift build -c release --disable-sandbox
BINARY="$(swift build -c release --show-bin-path)/ESPNowFlasher"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# Best-effort: the bundle is perfectly usable with the generic icon.
echo "==> Drawing the icon"
if swift Tools/make-icon.swift "$BUILD_DIR/Flasher.iconset" 2>/dev/null \
   && iconutil -c icns "$BUILD_DIR/Flasher.iconset" -o "$APP/Contents/Resources/Flasher.icns" 2>/dev/null; then
  ICON_ENTRY='<key>CFBundleIconFile</key><string>Flasher</string>'
else
  echo "    (skipped -- using the default icon)"
  ICON_ENTRY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_ENTRY
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for macOS to run it locally and to keep the app's
# identity stable across rebuilds, which is what stops the permission prompts
# from being asked again every time.
#
# The xattr sweep is not optional: copying files through Finder or a synced
# folder leaves extended attributes behind, and codesign rejects the whole
# bundle with "resource fork, Finder information, or similar detritus".
echo "==> Signing (ad-hoc)"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" \
  || echo "    (unsigned -- macOS may ask before the first launch)"

echo
echo "Built $APP"
echo "Move it to /Applications, or run: open '$APP'"

if [ "${1:-}" = "--open" ]; then
  open "$APP"
fi
