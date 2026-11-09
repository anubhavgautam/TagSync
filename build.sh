#!/bin/bash
# Builds TagSync.app (universal: Apple silicon + Intel) next to this script.
# Usage: ./build.sh [--install] [--dmg]
set -euo pipefail
cd "$(dirname "$0")"
APP="TagSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
VERSION="1.1"
BUILD="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14.0" Sources/*.swift -o "$BUILD/TagSync-$arch"
done
lipo -create "$BUILD"/TagSync-* -output "$APP/Contents/MacOS/TagSync"

# App icon from the Quintessence artwork
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift Assets/quintessence.svg "$BUILD/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TagSync</string>
  <key>CFBundleDisplayName</key><string>TagSync</string>
  <key>CFBundleIdentifier</key><string>local.tagsync</string>
  <key>CFBundleExecutable</key><string>TagSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP ($(du -sh "$APP" | cut -f1))"
for arg in "$@"; do
  case "$arg" in
    --install)
      rm -rf /Applications/TagSync.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications/TagSync.app" ;;
    --dmg)
      mkdir -p dist "$BUILD/dmg"
      cp -R "$APP" "$BUILD/dmg/" && ln -s /Applications "$BUILD/dmg/Applications"
      DMG="dist/TagSync-$VERSION.dmg"
      rm -f "$DMG"
      hdiutil create -volname "TagSync" -srcfolder "$BUILD/dmg" -ov -format UDZO "$DMG" >/dev/null
      echo "Created $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))" ;;
  esac
done
rm -rf "$BUILD"
