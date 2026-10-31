#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SCRATCH="$(mktemp -d /private/tmp/inotes-tests.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p .build/module-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
printf 'import XCTest\n' > "$SCRATCH/XCTestProbe.swift"
PROBE_OPTIONS=(-swift-version 5 -typecheck -module-cache-path "$CLANG_MODULE_CACHE_PATH")
DEVELOPER_TOOLS="$(xcode-select -p)"
XCTEST_FRAMEWORKS="$DEVELOPER_TOOLS/Platforms/MacOSX.platform/Developer/Library/Frameworks"
if [[ -d "$XCTEST_FRAMEWORKS" ]]; then PROBE_OPTIONS+=(-F "$XCTEST_FRAMEWORKS"); fi
if swiftc "${PROBE_OPTIONS[@]}" "$SCRATCH/XCTestProbe.swift" > "$SCRATCH/probe.log" 2>&1; then
  echo "Test backend: SwiftPM XCTest (full Xcode toolchain)"
  swift test --build-system native --disable-sandbox --cache-path "$ROOT/.build/cache" --scratch-path "$SCRATCH/package" --jobs 4
else
  PROBE_RESULT="$(<"$SCRATCH/probe.log")"
  if [[ "$PROBE_RESULT" != *"no such module 'XCTest'"* ]]; then
    echo "XCTest probe failed for a reason other than a missing module:" >&2
    cat "$SCRATCH/probe.log" >&2
    exit 1
  fi
  echo "Test backend: standalone runner for Command Line Tools (same XCTest test methods)"
  echo "XCTest is absent from this toolchain; using the dependency-free assertion adapter."
  swiftc -swift-version 5 -enable-testing -emit-module -emit-library -module-name NotesCore \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" Sources/NotesCore/*.swift \
    -o "$SCRATCH/libNotesCore.dylib" -emit-module-path "$SCRATCH/NotesCore.swiftmodule"
  swiftc -swift-version 5 -D INOTES_STANDALONE_TESTS -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$SCRATCH" -L "$SCRATCH" -lNotesCore -Xlinker -rpath -Xlinker "$SCRATCH" \
    Tests/NotesCoreTests/*.swift -o "$SCRATCH/CoreTests"
  "$SCRATCH/CoreTests"
fi
