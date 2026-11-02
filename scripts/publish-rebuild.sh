#!/bin/bash
set -euo pipefail

# Called only by the explicitly dispatched release workflow. The existing version
# tag and installer remain intact; a signed appcast is the last published asset.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${VERSION:?}" "${BUILD_NUMBER:?}" "${GITHUB_REPOSITORY:?}" "${RUNNER_TEMP:?}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 2
[[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] || { echo 'Rebuild publication requires an explicit workflow dispatch.' >&2; exit 2; }
TAG="v$VERSION"
NAME="iNotes-$VERSION-build$BUILD_NUMBER-arm64.dmg"
PREFIX="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG"
STATE="$RUNNER_TEMP/inotes-rebuild"
mkdir -p "$STATE"

download() {
  curl --fail --silent --show-error --location --retry 6 --retry-all-errors --retry-delay 2 "$1" --output "$2"
}

check_release() {
  gh api "repos/$GITHUB_REPOSITORY/releases/latest" > "$STATE/latest.json"
  python3 - "$STATE/latest.json" "$TAG" "$NAME" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
if release['tag_name'] != sys.argv[2] or release['draft'] or release['prerelease']:
    raise SystemExit('Only the current public stable release can be rebuilt.')
if any(a['name'] == sys.argv[3] or a['name'] == sys.argv[3] + '.sha256' for a in release['assets']):
    raise SystemExit('This build-numbered installer already exists. Start a new workflow run; never overwrite it.')
PY
}

case "${1:-}" in
  --preflight)
    check_release
    download "$PREFIX/appcast.xml" "$STATE/previous-appcast.xml"
    python3 - "$STATE/previous-appcast.xml" "$VERSION" "$BUILD_NUMBER" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1])
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
version = root.findtext('.//' + ns + 'shortVersionString')
builds = [int(e.text) for e in root.iter(ns + 'version')]
if version != sys.argv[2] or not builds or max(builds) >= int(sys.argv[3]):
    raise SystemExit('The proposed build must exceed the current same-version public update.')
PY
    echo "Existing release checked; preparing $TAG build $BUILD_NUMBER."
    ;;
  --publish)
    test -f "$STATE/previous-appcast.xml"
    test -f "dist/$NAME"
    test -f "dist/$NAME.sha256"
    test -f dist/update/appcast.xml
    check_release
    download "$PREFIX/appcast.xml" "$STATE/current-appcast.xml"
    cmp "$STATE/previous-appcast.xml" "$STATE/current-appcast.xml"
    # A collision fails instead of overwriting a previously shared installer.
    gh release upload "$TAG" "dist/$NAME" "dist/$NAME.sha256" --repo "$GITHUB_REPOSITORY"
    mkdir -p "$STATE/public"
    download "$PREFIX/$NAME" "$STATE/public/$NAME"
    download "$PREFIX/$NAME.sha256" "$STATE/public/$NAME.sha256"
    cmp "dist/$NAME" "$STATE/public/$NAME"
    cmp "dist/$NAME.sha256" "$STATE/public/$NAME.sha256"
    (cd "$STATE/public" && shasum -a 256 -c "$NAME.sha256")
    swift -module-cache-path .build/module-cache scripts/verify-update.swift \
      Resources/UpdatePublicEDKey.txt dist/update/appcast.xml "$STATE/public/$NAME"
    # Stop if anyone changed the live update while the installer was uploaded.
    download "$PREFIX/appcast.xml" "$STATE/current-appcast.xml"
    cmp "$STATE/previous-appcast.xml" "$STATE/current-appcast.xml"
    notes="docs/releases/$VERSION.md"
    test -f "$notes"
    cp "$notes" "$STATE/release-notes.md"
    printf '\nRebuild source: `%s` · Build **%s**. The original version tag still identifies the original installer.\n' \
      "$GITHUB_SHA" "$BUILD_NUMBER" >> "$STATE/release-notes.md"
    gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --notes-file "$STATE/release-notes.md"
    # All installer/public-byte checks completed. Replace the signed feed last.
    # If GitHub replacement fails after deleting the old asset, attempt to restore
    # its original signed bytes without editing or resigning them.
    if ! gh release upload "$TAG" dist/update/appcast.xml --repo "$GITHUB_REPOSITORY" --clobber; then
      mkdir -p "$STATE/restore"
      cp "$STATE/previous-appcast.xml" "$STATE/restore/appcast.xml"
      gh release upload "$TAG" "$STATE/restore/appcast.xml" --repo "$GITHUB_REPOSITORY" --clobber || true
      echo 'Feed replacement failed; attempted to restore the previous signed feed.' >&2
      exit 1
    fi
    download "$PREFIX/appcast.xml" "$STATE/public/appcast.xml"
    download "https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml" "$STATE/public/latest-appcast.xml"
    cmp dist/update/appcast.xml "$STATE/public/appcast.xml"
    cmp dist/update/appcast.xml "$STATE/public/latest-appcast.xml"
    swift -module-cache-path .build/module-cache scripts/verify-update.swift \
      Resources/UpdatePublicEDKey.txt "$STATE/public/latest-appcast.xml" "$STATE/public/$NAME"
    echo "Published and verified $TAG build $BUILD_NUMBER; original tag and installers preserved."
    ;;
  *) echo 'Use --preflight or --publish.' >&2; exit 2 ;;
esac
