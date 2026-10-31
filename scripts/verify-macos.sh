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
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$MOUNT" >/dev/null || true; fi
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
MOUNTED=1
APP="$MOUNT/iNotes.app"
test -x "$APP/Contents/MacOS/iNotes"
test "$(readlink "$MOUNT/Applications")" = "/Applications"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -verify_arch arm64 "$APP/Contents/MacOS/iNotes"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = "14.0"
"$APP/Contents/MacOS/iNotes" --smoke-test
echo "Verified mounted DMG, app signature, ARM64 executable, deployment target, Applications link, and persistence smoke test."
