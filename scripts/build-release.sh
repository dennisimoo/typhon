#!/usr/bin/env bash
# Builds Typhon.app (Release), then packages dist/Typhon-<version>.dmg and a Sparkle zip.
#
#   scripts/build-release.sh            # ad-hoc signed (anyone can run this)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-release.sh
#   NOTARY_PROFILE=typhon scripts/build-release.sh   # also notarize (xcrun notarytool store-credentials)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(grep -E '^MARKETING_VERSION' Config/Typhon.xcconfig | awk '{print $3}')}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
DERIVED=build/release
APP="$DERIVED/Build/Products/Release/Typhon.app"
mkdir -p dist build

command -v create-dmg >/dev/null || { echo "Install create-dmg: brew install create-dmg"; exit 1; }

echo "▸ Building Typhon $VERSION"
xcodebuild -project Typhon.xcodeproj -scheme Typhon -configuration Release \
  -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation \
  MARKETING_VERSION="$VERSION" CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" build > build/release.log 2>&1 \
  || { tail -40 build/release.log; echo "Build failed (full log: build/release.log)"; exit 1; }

echo "▸ Signing ($SIGN_IDENTITY)"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements Typhon/Typhon.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Creating DMG"
[ -f scripts/dmg/background.png ] || swift scripts/make-dmg-background.swift
DMG="dist/Typhon-$VERSION.dmg"
rm -f "$DMG"
create-dmg \
  --volname "Typhon" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background scripts/dmg/background.png \
  --window-pos 200 120 --window-size 660 400 \
  --icon-size 112 --text-size 13 \
  --icon "Typhon.app" 180 200 --hide-extension "Typhon.app" \
  --app-drop-link 480 200 \
  --no-internet-enable \
  "$DMG" "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "▸ Creating Sparkle update archive"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Typhon-$VERSION.zip"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ dist/Typhon-$VERSION.dmg"
