#!/bin/bash
set -euo pipefail

# Direct distribution for Apple silicon. No package manager or third-party runtime.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "VERSION must be x.y.z and BUILD_NUMBER must be numeric." >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script requires macOS, Apple command line tools, and hdiutil." >&2
  exit 2
fi

mkdir -p dist .build/module-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
SCRATCH="$(mktemp -d /private/tmp/inotes-build.XXXXXX)"
STAGE="$(mktemp -d "$ROOT/dist/.package.XXXXXX")"
cleanup() {
  # Restore the previous app if publishing the new bundle did not complete.
  if [[ -d "$STAGE/previous-iNotes.app" && ! -e "$ROOT/dist/iNotes.app" ]]; then
    mv "$STAGE/previous-iNotes.app" "$ROOT/dist/iNotes.app"
  fi
  rm -rf "$STAGE"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
BUILD_OPTIONS=(--build-system native --disable-sandbox --cache-path "$ROOT/.build/cache" --scratch-path "$SCRATCH" -c release --arch arm64)
swift build "${BUILD_OPTIONS[@]}" --product iNotes
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
APP="$STAGE/iNotes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/iNotes" "$APP/Contents/MacOS/iNotes"
cp LICENSE "$APP/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$STAGE/iNotes.iconset"
iconutil -c icns "$STAGE/iNotes.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>iNotes</string>
  <key>CFBundleDisplayName</key><string>iNotes</string>
  <key>CFBundleIdentifier</key><string>io.inotes.app</string>
  <key>CFBundleExecutable</key><string>iNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 iNotes contributors. MIT License.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>iNotes Archive</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>io.inotes.archive</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>io.inotes.archive</string>
    <key>UTTypeDescription</key><string>iNotes Archive</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>inotes</string></array></dict>
  </dict></array>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
lipo -verify_arch arm64 "$APP/Contents/MacOS/iNotes"
"$APP/Contents/MacOS/iNotes" --smoke-test

DMG_ROOT="$STAGE/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/iNotes.app"
ln -s /Applications "$DMG_ROOT/Applications"
cp Resources/Install.txt "$DMG_ROOT/Install.txt"
DMG="$ROOT/dist/iNotes-$VERSION-arm64.dmg"
TEMP_DMG="$STAGE/iNotes-$VERSION-arm64.dmg"
hdiutil create -volname "iNotes $VERSION" -srcfolder "$DMG_ROOT" -format UDZO -ov "$TEMP_DMG"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --timestamp --sign "$SIGNING_IDENTITY" "$TEMP_DMG"
fi
# A profile must be explicitly supplied by a release maintainer to upload to Apple.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Notarization requires a Developer ID SIGNING_IDENTITY." >&2
    exit 2
  fi
  xcrun notarytool submit "$TEMP_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$TEMP_DMG"
  xcrun stapler validate "$TEMP_DMG"
fi
hdiutil verify "$TEMP_DMG"
# Publish only after signing, packaging and image verification succeed.
if [[ -e "$ROOT/dist/iNotes.app" ]]; then
  mv "$ROOT/dist/iNotes.app" "$STAGE/previous-iNotes.app"
fi
mv "$APP" "$ROOT/dist/iNotes.app"
mv -f "$TEMP_DMG" "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built $DMG"
du -sh "$ROOT/dist/iNotes.app" "$DMG"
