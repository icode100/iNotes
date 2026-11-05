#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.2.0}"
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
test -s "$APP/Contents/Resources/SwiftMath-LICENSE"
python3 - "$APP/Contents/Resources/iNotes_NotesApp.bundle/WorkspaceThemes" <<'PY'
from pathlib import Path
import hashlib, struct, sys
themes = Path(sys.argv[1])
expected = {
    'coast-dark.png': '276fc058bc4f88d0f201845d0ba936105698ebe7806ec171d88b4c4f15b94747',
    'coast-light.png': 'd56b4e9d1352eb38eae1fa1b225b397f523053c14e1cb7f8ecbe4ba00c35665c',
    'alpine-dark.png': 'b9a6af3e1d3139b8ab5db5bb9ce6ab675c5594040252ac6a6d26bc48f2090928',
    'alpine-light.png': '75ffd26d7701adbaebfad85280f7822ba7c202e9bdfffeae8c216d76cfabb79d',
    'arctic-dark.png': '4b6fc91008c76997d332aa7b661362df70850d24ea5f74a669af4b08c5855de9',
    'arctic-light.png': '941ec400d2270a94fc2409d605dbe5fdcce061f1ee231cf4a5c80f795a5a5ff7',
    'open-skyscape-dark.png': '4808fd207f43d16ebf1f45a43987b5e465450916264ab012c7b18d788fccb173',
    'open-skyscape-light.png': '096c2550076c65a6cb0a93ff4a95fc3b3d57387104237dc069e2815a0988f016',
    'ruby-hills-dark.png': '9d1544274a9f0850d7c676a6f3bb77a6955f5f1326509df5710a94565880d756',
    'ruby-hills-light.png': 'b683c238985311d58b3b91daaf0358f045968f71d3820132692fb27b148b9f68',
    'nature-dark.png': '53e5cac550555d4c8b7eb17f76c07a7bfcb105e5045e4c70febebbca65d4f3db',
    'nature-light.png': 'dcb4f7cbad2bde80881878615471979bbcf64928ad2c6da746c87f4bbb21b487',
}
assert {path.name for path in themes.iterdir()} == set(expected), 'Missing or unexpected workspace theme assets'
for name, digest in expected.items():
    data = (themes / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest, f'Changed workspace artwork: {name}'
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', f'Invalid PNG: {name}'
    assert struct.unpack('>II', data[16:24]) == (1672, 941), f'Unexpected image dimensions: {name}'
print('Verified all twelve original light/dark workspace theme images and their exact SHA-256 hashes.')
PY
MATH_FONTS="$APP/Contents/Resources/SwiftMath_SwiftMath.bundle/mathFonts.bundle"
test -s "$MATH_FONTS/latinmodern-math.otf"
test -s "$MATH_FONTS/latinmodern-math.plist"
test -s "$MATH_FONTS/LICENSE"
test -s "$MATH_FONTS/GUST-FONT-LICENSE.txt"
python3 - "$MATH_FONTS" <<'PY'
from pathlib import Path
import plistlib, sys
fonts = Path(sys.argv[1])
assert {path.name for path in fonts.glob('*.otf')} == {'latinmodern-math.otf'}, 'Unexpected bundled math fonts'
assert {path.name for path in fonts.glob('*.plist')} == {'latinmodern-math.plist'}, 'Unexpected math font layout tables'
with (fonts / 'latinmodern-math.otf').open('rb') as source:
    assert source.read(4) == b'OTTO', 'Invalid OpenType math font'
with (fonts / 'latinmodern-math.plist').open('rb') as source:
    assert plistlib.load(source)['version'] == '1.3', 'Invalid math layout tables'
print('Verified complete Latin Modern math font, native layout tables and license notices; unused fonts omitted.')
PY
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
