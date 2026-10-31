#!/bin/bash
set -euo pipefail
BUNDLE="${1:?Pass the copied SwiftMath_SwiftMath.bundle path}"
python3 - "$BUNDLE" <<'PY'
from pathlib import Path
import sys
fonts = Path(sys.argv[1]) / 'mathFonts.bundle'
required = {'latinmodern-math.otf', 'latinmodern-math.plist'}
if not fonts.is_dir() or not all((fonts / name).is_file() for name in required):
    raise SystemExit('Missing the complete Latin Modern math font or layout tables.')
# Keep the selected font unmodified, including every glyph, and all license notices.
for path in fonts.iterdir():
    if path.is_file() and path.suffix in {'.otf', '.plist'} and path.name not in required:
        path.unlink()
PY
