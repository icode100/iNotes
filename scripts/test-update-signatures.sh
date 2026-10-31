#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.2.2}"
FEED="${1:-dist/update/appcast.xml}"
ARCHIVE="${2:-dist/iNotes-$VERSION-arm64.dmg}"
STAGE="$(mktemp -d /private/tmp/inotes-update-tests.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p .build/module-cache
VERIFY=(swift -module-cache-path .build/module-cache scripts/verify-update.swift)
"${VERIFY[@]}" Resources/UpdatePublicEDKey.txt "$FEED" "$ARCHIVE"
python3 - "$FEED" "$ARCHIVE" "$STAGE" <<'PY'
import base64, pathlib, sys
feed, archive, stage = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
data = feed.read_bytes()
(stage / 'tampered.xml').write_bytes(data.replace(b'<title>', b'<TITLE>', 1))
(stage / 'unsigned.xml').write_bytes(data.split(b'<!-- sparkle-signatures:')[0])
copy = bytearray(archive.read_bytes())
copy[len(copy) // 2] ^= 1
(stage / archive.name).write_bytes(copy)
(stage / 'wrong-public-key.txt').write_text(base64.b64encode(bytes(32)).decode())
PY
reject() {
  if "${VERIFY[@]}" "$@" > "$STAGE/last-result.log" 2>&1; then
    echo "Unsafe update was unexpectedly accepted." >&2
    exit 1
  fi
}
reject Resources/UpdatePublicEDKey.txt "$STAGE/tampered.xml" "$ARCHIVE"
reject Resources/UpdatePublicEDKey.txt "$STAGE/unsigned.xml" "$ARCHIVE"
reject Resources/UpdatePublicEDKey.txt "$FEED" "$STAGE/$(basename "$ARCHIVE")"
reject "$STAGE/wrong-public-key.txt" "$FEED" "$ARCHIVE"
echo "Passed five update-signature checks: valid feed/archive, changed feed, unsigned feed, changed archive, wrong key."
