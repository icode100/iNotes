#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
DMG="${1:-$ROOT/dist/iNotes-$VERSION-arm64.dmg}"
if [[ ! -f "$DMG" ]]; then
  echo "DMG not found: $DMG" >&2
  exit 2
fi
hdiutil verify "$DMG"
if [[ -f "$DMG.sha256" ]]; then
  (cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256")
fi
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/inotes-verify.XXXXXX")"
ICON_INFO="$(mktemp "${TMPDIR:-/tmp}/inotes-icon-assets.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$MOUNT" >/dev/null || true; fi
  rmdir "$MOUNT" 2>/dev/null || true
  rm -f "$ICON_INFO"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
MOUNTED=1
APP="$MOUNT/iNotes.app"
test -x "$APP/Contents/MacOS/iNotes"
test "$(readlink "$MOUNT/Applications")" = "/Applications"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/iNotes" -verify_arch arm64
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
test -f "$APP/Contents/Resources/Sparkle-LICENSE"
for BINARY in "$FRAMEWORK/Versions/B/Sparkle" "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"; do
  test "$(lipo "$BINARY" -archs)" = "arm64"
  codesign --verify --strict "$BINARY"
done
test ! -e "$FRAMEWORK/XPCServices"
python3 - "$APP/Contents/Info.plist" <<'PY'
import base64, plistlib, sys
from urllib.parse import urlsplit
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
if 'SUFeedURL' in info or 'SUPublicEDKey' in info:
    feed = urlsplit(info['SUFeedURL'])
    assert feed.scheme == 'https' and feed.hostname and not feed.username and not feed.password
    assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
    assert info['SUVerifyUpdateBeforeExtraction'] is True and info['SURequireSignedFeed'] is True
    assert info['SUSignedFeedFailureExpirationInterval'] == 0
    assert info['SUEnableSystemProfiling'] is False
    print('Verified signed-feed and archive enforcement; profiling disabled.')
else:
    print('Verified dormant updater with no release configuration.')
PY
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist")" = "AppIcon"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/Assets.car"
assetutil --info "$APP/Contents/Resources/Assets.car" > "$ICON_INFO"
python3 - "$ICON_INFO" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    assets = json.load(source)
appearances = {
    item.get("Appearance") for item in assets
    if item.get("AssetType") == "IconImageStack" and item.get("Name") == "AppIcon"
}
required = {"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"}
if not required.issubset(appearances):
    raise SystemExit("The packaged app icon is missing native light/dark appearances.")
print("Verified native light/dark icon stacks and the older-macOS ICNS fallback.")
PY
"$APP/Contents/MacOS/iNotes" --smoke-test
echo "Verified mounted DMG, app signature, ARM64 executable, deployment target, Applications link, and persistence smoke test."
