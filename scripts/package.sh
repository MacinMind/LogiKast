#!/bin/bash
# Builds a Release iceKast, signs it with the MacinMind Developer ID, and packs it into a DMG
# in build/release/. NOT notarized: on another Mac, copy it without the download quarantine
# flag (USB, network share, scp) or see the notes printed at the end.
#
# Usage: scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="Developer ID Application: MacinMind Software, Inc. (2D3239GKS4)"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/xcode-release"

security find-identity -v -p codesigning | grep -q "$IDENTITY" || { echo "error: signing identity not found: $IDENTITY" >&2; exit 1; }
[ -x build/icecast/icecast ] || { echo "error: run scripts/build-icecast.sh first" >&2; exit 1; }

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"([^"]+)".*/\1/p' project.yml)
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"([^"]+)".*/\1/p' project.yml)
echo "== iceKast $VERSION (build $BUILD)"

echo "== Building Release (universal)"
xcodegen generate >/dev/null
xcodebuild -project iceKast.xcodeproj -scheme iceKast -configuration Release \
  -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO clean build 2>&1 | grep -E "error:|warning: .*sign|BUILD (SUCCEEDED|FAILED)"

APP="$DERIVED/Build/Products/Release/iceKast.app"
[ -d "$APP" ] || { echo "error: build failed" >&2; exit 1; }

echo "== Verifying"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -2
for f in "$APP" "$APP/Contents/Helpers/icecast" "$APP/Contents/Helpers/icekast-launch"; do
  info=$(codesign -dvv "$f" 2>&1)
  echo "$(basename "$f"): $(echo "$info" | sed -nE 's/^Authority=(Developer ID Application.*)/\1/p' | head -1) | $(echo "$info" | grep -o 'flags=0x[0-9a-f]*([a-z,]*)') | timestamp: $(echo "$info" | grep -c '^Timestamp=')"
  bin="$f"; [ -d "$f" ] && bin="$f/Contents/MacOS/iceKast"
  lipo -archs "$bin" | sed 's/^/    archs: /'
done
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleShortVersionString|\"CFBundleVersion|LSMinimumSystemVersion"

echo "== Creating DMG"
rm -rf "$OUT"; mkdir -p "$OUT/stage"
cp -R "$APP" "$OUT/stage/"
ln -s /Applications "$OUT/stage/Applications"
DMG="$OUT/iceKast-$VERSION.dmg"
hdiutil create -volname "iceKast $VERSION" -srcfolder "$OUT/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/stage"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=1 "$DMG" 2>&1 | tail -1
shasum -a 256 "$DMG" | tee "$DMG.sha256"
ls -lh "$DMG" | awk '{print "size:", $5}'
echo "== Gatekeeper's verdict on this unnotarized build (expected: rejected, 'Unnotarized Developer ID'):"
spctl --assess --type execute -vv "$APP" 2>&1 | head -3 || true
