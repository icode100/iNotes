#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.2.2}"
ARCHIVE="${1:-$ROOT/dist/iNotes-$VERSION-arm64.dmg}"
OUTPUT="${2:-$ROOT/dist/update}"
UPDATE_PRIVATE_KEY_FILE="${UPDATE_PRIVATE_KEY_FILE:-$ROOT/.private/updates/ed25519.key}"
UPDATE_DOWNLOAD_URL_PREFIX="${UPDATE_DOWNLOAD_URL_PREFIX:-https://github.com/icode100/iNotes/releases/download/v$VERSION/}"
if [[ ! -f "$ARCHIVE" || ! -f "$UPDATE_PRIVATE_KEY_FILE" ]]; then
  echo "A built DMG and the project's private Ed25519 key file are required; nothing was published." >&2
  exit 2
fi
# Validate the secret before Sparkle is allowed to read it (its invalid-key errors may echo input).
python3 - "$UPDATE_PRIVATE_KEY_FILE" "$UPDATE_DOWNLOAD_URL_PREFIX" <<'PY'
import base64, pathlib, sys
from urllib.parse import urlsplit
try:
    valid = len(base64.b64decode(pathlib.Path(sys.argv[1]).read_text().strip(), validate=True)) == 32
except Exception:
    valid = False
try:
    url = urlsplit(sys.argv[2])
    port = url.port
except ValueError:
    raise SystemExit('Invalid HTTPS download prefix.')
if (not valid or url.scheme != 'https' or not url.hostname or url.username or url.password
        or url.fragment or (port is not None and not 1 <= port <= 65535)):
    raise SystemExit('A valid project signing seed and HTTPS download prefix are required.')
PY
SPARKLE_TOOLS="${SPARKLE_TOOLS:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
if [[ ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
  swift package --disable-sandbox --cache-path "$ROOT/.build/cache" resolve
fi
mkdir -p "$OUTPUT" "$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
STAGE="$(mktemp -d /private/tmp/inotes-appcast.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/$(basename "$ARCHIVE")"
"$SPARKLE_TOOLS/generate_appcast" --ed-key-file "$UPDATE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$UPDATE_DOWNLOAD_URL_PREFIX" --maximum-deltas 0 "$STAGE"
"$SPARKLE_TOOLS/sign_update" --ed-key-file "$UPDATE_PRIVATE_KEY_FILE" "$STAGE/appcast.xml"
swift -module-cache-path "$ROOT/.build/module-cache" scripts/verify-update.swift \
  Resources/UpdatePublicEDKey.txt "$STAGE/appcast.xml" "$ARCHIVE"
cp "$STAGE/appcast.xml" "$OUTPUT/appcast.xml"
echo "Signed appcast prepared: $OUTPUT/appcast.xml. No files were uploaded."
