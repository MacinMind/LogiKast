#!/bin/bash
# Builds a Release LogiKast, signs it with the MacinMind Developer ID, and packs it into a DMG
# in build/release/. NOT notarized: on another Mac, copy it without the download quarantine
# flag (USB, network share, scp) or see the notes printed at the end.
#
# Usage: scripts/package.sh [--notarize]
#   --notarize   also notarize + staple the app and the DMG (needs a saved notarytool profile,
#                default name "icekast-notary"; override with NOTARY_PROFILE=...).
#                Create it once with:
#                  xcrun notarytool store-credentials icekast-notary \
#                    --apple-id <developer Apple ID> --team-id 2D3239GKS4
set -euo pipefail

NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1
PROFILE="${NOTARY_PROFILE:-icekast-notary}"

# Submits a file to Apple and waits. Prints Apple's log if it is not accepted.
notarize() {
  local file="$1" out
  echo "   submitting $(basename "$file") (this usually takes a few minutes)..."
  out=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out" | sed 's/^/   /' | grep -E "id:|status:|message:" | head -6
  if ! echo "$out" | grep -q "status: Accepted"; then
    local id; id=$(echo "$out" | sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' | head -1)
    echo "error: notarization of $(basename "$file") was not accepted" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || echo "$out" >&2
    exit 1
  fi
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="Developer ID Application: MacinMind Software, Inc. (2D3239GKS4)"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/xcode-release"

security find-identity -v -p codesigning | grep -q "$IDENTITY" || { echo "error: signing identity not found: $IDENTITY" >&2; exit 1; }
if [ "$NOTARIZE" = 1 ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "error: no working notarytool profile '$PROFILE'. See the usage note at the top of this script." >&2; exit 1; }
fi
[ -x build/icecast/icecast ] || { echo "error: run scripts/build-icecast.sh first" >&2; exit 1; }

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"([^"]+)".*/\1/p' project.yml)
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"([^"]+)".*/\1/p' project.yml)
echo "== LogiKast $VERSION (build $BUILD)"

echo "== Building Release (universal)"
xcodegen generate >/dev/null
xcodebuild -project LogiKast.xcodeproj -scheme LogiKast -configuration Release \
  -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO clean build 2>&1 | grep -E "error:|warning: .*sign|BUILD (SUCCEEDED|FAILED)"

APP="$DERIVED/Build/Products/Release/LogiKast.app"
[ -d "$APP" ] || { echo "error: build failed" >&2; exit 1; }

echo "== Verifying"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -2
for f in "$APP" "$APP/Contents/Helpers/icecast" "$APP/Contents/Helpers/logikast-launch"; do
  info=$(codesign -dvv "$f" 2>&1)
  echo "$(basename "$f"): $(echo "$info" | sed -nE 's/^Authority=(Developer ID Application.*)/\1/p' | head -1) | $(echo "$info" | grep -o 'flags=0x[0-9a-f]*([a-z,]*)') | timestamp: $(echo "$info" | grep -c '^Timestamp=')"
  bin="$f"; [ -d "$f" ] && bin="$f/Contents/MacOS/LogiKast"
  lipo -archs "$bin" | sed 's/^/    archs: /'
done
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleShortVersionString|\"CFBundleVersion|LSMinimumSystemVersion"

rm -rf "$OUT"; mkdir -p "$OUT"
if [ "$NOTARIZE" = 1 ]; then
  echo "== Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/LogiKast-app.zip"
  notarize "$OUT/LogiKast-app.zip"
  rm -f "$OUT/LogiKast-app.zip"
  xcrun stapler staple "$APP" 2>&1 | tail -1
  xcrun stapler validate "$APP" 2>&1 | tail -1
fi

echo "== Creating DMG"
mkdir -p "$OUT/stage"
cp -R "$APP" "$OUT/stage/"
ln -s /Applications "$OUT/stage/Applications"
DMG="$OUT/LogiKast-$VERSION.dmg"
hdiutil create -volname "LogiKast $VERSION" -srcfolder "$OUT/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/stage"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=1 "$DMG" 2>&1 | tail -1
if [ "$NOTARIZE" = 1 ]; then
  echo "== Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG" 2>&1 | tail -1
  xcrun stapler validate "$DMG" 2>&1 | tail -1
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
ls -lh "$DMG" | awk '{print "size:", $5}'
echo "== Gatekeeper's verdict on the app:"
spctl --assess --type execute -vv "$APP" 2>&1 | head -3 || true
if [ "$NOTARIZE" = 1 ]; then
  echo "== Gatekeeper's verdict on the DMG:"
  spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | head -3 || true
fi
