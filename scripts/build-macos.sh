#!/bin/bash
set -euo pipefail

# Direct distribution for Apple silicon, with a native signed Sparkle updater.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.4}"
BUILD_NUMBER="${BUILD_NUMBER:-2016}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
export UPDATE_FEED_URL="${UPDATE_FEED_URL-https://github.com/icode100/iNotes/releases/latest/download/appcast.xml}"
if [[ ! ${UPDATE_PUBLIC_ED_KEY+x} && -f Resources/UpdatePublicEDKey.txt ]]; then
  UPDATE_PUBLIC_ED_KEY="$(cat Resources/UpdatePublicEDKey.txt)"
fi
export UPDATE_PUBLIC_ED_KEY="${UPDATE_PUBLIC_ED_KEY:-}"
# Reject partial or malformed release settings before spending time on a build.
python3 scripts/update-config.py --validate
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "VERSION must be x.y.z and BUILD_NUMBER must be numeric." >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script requires macOS, Apple command line tools, and hdiutil." >&2
  exit 2
fi
if ! xcrun --find actool >/dev/null 2>&1; then
  echo "Full Xcode with actool is required to compile the adaptive light/dark app icon." >&2
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
# Snapshot source inputs: concurrent edits to an iPad-only file must not invalidate
# an otherwise unchanged Mac compilation halfway through packaging.
mkdir -p "$SCRATCH/source"
ditto Sources "$SCRATCH/source/Sources"
ditto Tests "$SCRATCH/source/Tests"
cp Package.swift Package.resolved "$SCRATCH/source/"
BUILD_OPTIONS=(--package-path "$SCRATCH/source" --build-system native --disable-sandbox --cache-path "$ROOT/.build/cache" --scratch-path "$SCRATCH" -c release --arch arm64)
swift package --package-path "$SCRATCH/source" --disable-sandbox --cache-path "$ROOT/.build/cache" --scratch-path "$SCRATCH" resolve
# Adapt only the pinned dependency's native resource lookup, inside disposable scratch.
MATH_SOURCE="$SCRATCH/checkouts/SwiftMath/Sources/SwiftMath/MathRender/MTFont.swift"
chmod u+w "$MATH_SOURCE"
patch -p1 -d "$SCRATCH/checkouts/SwiftMath" < patches/SwiftMath-1.7.3-resource-bundle.patch
swift build "${BUILD_OPTIONS[@]}" --product iNotes
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
APP="$STAGE/iNotes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/iNotes" "$APP/Contents/MacOS/iNotes"
cp LICENSE "$APP/Contents/Resources/LICENSE"
ditto "$BIN_DIR/iNotes_NotesApp.bundle" "$APP/Contents/Resources/iNotes_NotesApp.bundle"
ditto "$BIN_DIR/SwiftMath_SwiftMath.bundle" "$APP/Contents/Resources/SwiftMath_SwiftMath.bundle"
bash scripts/trim-math-fonts.sh "$APP/Contents/Resources/SwiftMath_SwiftMath.bundle"
cp "$SCRATCH/checkouts/SwiftMath/LICENSE" "$APP/Contents/Resources/SwiftMath-LICENSE"
SPARKLE_DIST="$SCRATCH/artifacts/sparkle/Sparkle"
SPARKLE_SOURCE="$SPARKLE_DIST/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$SPARKLE_SOURCE"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_DIST/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# The app is not sandboxed. Sparkle explicitly permits omitting unused XPC services.
# Keep its installer and updater helpers; neither runs as a persistent service.
rm -rf "$FRAMEWORK/Versions/B/XPCServices" "$FRAMEWORK/XPCServices"
# Ship only the architecture supported by this app, then re-sign inside out.
for BINARY in "$FRAMEWORK/Versions/B/Sparkle" "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"; do
  lipo "$BINARY" -thin arm64 -output "$BINARY.arm64"
  mv "$BINARY.arm64" "$BINARY"
done
swift scripts/make-icon.swift "$STAGE/iNotes.iconset"
iconutil -c icns "$STAGE/iNotes.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Compile the native layered icon, including true Aqua/Dark Aqua renditions.
# Keep the hand-tuned ICNS above as the fallback for older macOS versions.
swift scripts/make-icon.swift "$STAGE/PencilForeground.iconset" --foreground
ditto Resources/AppIcon.icon "$STAGE/AppIcon.icon"
cp "$STAGE/PencilForeground.iconset/icon_512x512@2x.png" "$STAGE/AppIcon.icon/Assets/Pencil.png"
mkdir -p "$STAGE/adaptive-icons"
xcrun actool "$STAGE/AppIcon.icon" --compile "$STAGE/adaptive-icons" \
  --platform macosx --minimum-deployment-target 14.0 --target-device mac \
  --app-icon AppIcon --output-partial-info-plist "$STAGE/icon-info.plist" \
  --output-format human-readable-text
cp "$STAGE/adaptive-icons/Assets.car" "$APP/Contents/Resources/Assets.car"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>iNotes</string>
  <key>CFBundleDisplayName</key><string>iNotes</string>
  <key>CFBundleIdentifier</key><string>io.inotes.app</string>
  <key>CFBundleExecutable</key><string>iNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
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
python3 scripts/update-config.py "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
# Never use --deep for signing: each nested executable needs its own signature.
SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/iNotes" -verify_arch arm64
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
echo "Bundled Sparkle framework: $(du -sh "$ROOT/dist/iNotes.app/Contents/Frameworks/Sparkle.framework" | cut -f1)"
