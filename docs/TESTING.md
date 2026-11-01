# Validation

## Security fixes following v1.0.3 — 1 November 2026

Base revision `00092ba27e1da89fec5aad861f35962bc49afd29`. Codex Security's
standard scan `c3e91e99-3be2-492a-b271-db0eaeb986c3` covered all 78 tracked
text/source/configuration files; 10 PNG assets were inventoried only. It reported
two Low findings: `resource-exhaustion.import-hierarchy` (CWE-407) and
`resource-exhaustion.attachment-unbounded-read` (CWE-367). The original scan was
static; the follow-up fix-finding workflow used a fresh pre-patch investigator,
parent source tracing, and one independent read-only candidate reviewer. The
reviewer reported no concrete surviving bypass or compatibility regression.

Folder queries now build a parent-to-children index and traverse each subtree
once. Import no longer repeats the same sheet query. Attachment and archive
reads share `BoundedFileReader`: one nonblocking descriptor, regular-file/size
checks on that descriptor, 64 KiB chunks, and at most one byte beyond the caller's
limit. The picker stays at 10 MiB; archives stay at 64 MiB and still accept
individual embedded attachments larger than the picker limit. No archive schema,
editor/cursor, pressure, navigation-animation, or dependency change was made.

The source-frozen local candidate was tested in a disposable repository with
temporary libraries on macOS 27.2 (26B123), Xcode 27.2 (27B52):

| Gate / command | Observed result |
| --- | --- |
| `git diff --check`; Swift compilation in `bash scripts/test.sh` | Passed |
| Security-trigger and compatibility tests within `scripts/test.sh` | 78 XCTest tests passed. Ten new methods cover near-limit leaf-first archives, subtree semantics, exact/empty files, dense/sparse oversize, growth after metadata, short reads, pathname replacement, FIFO/directory rejection, symlinks, and archived attachments above 10 MiB |
| Command-line-tools standalone runner, compiled with `INOTES_STANDALONE_TESTS` | Same 78 methods passed, zero failures |
| `bash scripts/build-macos.sh`; `bash scripts/verify-macos.sh` | Passed ARM64 packaging, strict ad hoc signatures, mounted-DMG checks, resource hashes and store/backup integration |
| `dist/iNotes.app/Contents/MacOS/iNotes --smoke-test --editor-test` | Passed 260 editor, 399 workspace, 31 equation, 12 ruled-text and 8 shortcut checks, plus store/backup and 16 updater configuration checks |
| `xcodebuild -project iNotes.xcodeproj -scheme iNotes-iPad -destination 'generic/platform=iOS Simulator' -derivedDataPath ../ipad-derived CODE_SIGNING_ALLOWED=NO build` | Passed shared-source iPad simulator compilation |
| `bash scripts/generate-appcast.sh`; `bash scripts/test-update-signatures.sh` | Passed local feed/archive signature verification and all five valid/tampered/wrong-key cases |

The new actual-store regression imported a valid 49,127-node archive (49,000
leaf-first sheets and 127 ancestors) in 1.065 seconds and queried its folder in
0.019 seconds in the packaged native harness. It checked preserved pre-existing
notes, untitled numbering/order, text/ink, search, Favorites, Trash, moves and
saving. The helper-only debug query took 0.021 seconds. These are observed local
measurements, not a guarantee for every notebook or device. Growth tests change
real files after the descriptor check and assert exactly 10 MiB + 1 bytes consumed
before rejection; sparse growth to 1,000 MiB does not load the whole file.

The initial restricted test run passed the new regressions but failed two existing
backup tests because native `NSFileCoordinator` access was blocked. The complete
suite passed with native macOS access; no assertion or backup code was weakened.
Existing Swift concurrency/deprecated build-system warnings remain. The local
navigation harness passed, but this does not resolve the separately reported
hosted v1.0.3 CI navigation failure. No new physical tablet/Pencil, actual displayed
system-cursor capture, older-OS, cloud-upload, dependency-CVE or notarization result
is claimed. The original scan remains sealed; fix evidence is retained separately.

Initial local QA artifact (version 1.0.3 / build 2010): 29,603,237 regular app-file
bytes; DMG 24,628,282 bytes; SHA-256
`3c7a399bebe5cc276773ee1682a9e0e488ce1aaea5661cef047e617f81513184`.
This identifies the pre-publication test artifact, not the later higher-build
same-version update requested by the user. Do not publish this build 2010 over
an existing build 2010 or edit a signed feed to change its version.

### Final same-version build 2011

The final build keeps marketing version 1.0.3 and increases `CFBundleVersion` to
2011. Its freshly built installer passed `verify-macos.sh`, the full native
`--smoke-test --editor-test` suite (same counts above), iPad compilation, regenerated
feed signing, and all five signature probes. Its actual-store near-limit import
took 0.921 seconds and folder query 0.018 seconds. The build-numbered DMG is
`iNotes-1.0.3-build2011-arm64.dmg`, 24,631,093 bytes, SHA-256
`f7b77a9e42c3a9f253d7cc3dcdbbab1e1b56b7aba73ed8212f9fc00c6e342dfd`.
This local binary is the publication candidate; verification of downloaded public
assets is recorded separately after upload. Publication keeps the original tag
and installer, with the signed appcast switched only after the new installer is
publicly verified. The next hosted release run reserves build 2012.

## Millimetre nibs and navigation — local 1.0.3 candidate

This candidate retains the navigation fixes, restores pre-experiment writing
behavior, and makes Fine the default for each writing-tool selection. Requested
nominal presets (Extra Fine/Fine/Medium/Broad) are 0.3/0.45/0.7/1 mm for Pen,
Pencil, and Straight line, and 0.5/0.7/1/1.5 mm for Brush/Marker. Highlighter retains
its earlier choices. Conversion uses 72/25.4 points per millimetre and compensates
for existing style multipliers before storage; existing stroke archives are unchanged.
Native PencilKit and earlier tablet handling remain as before. The canceled pressure
boost, completed-stroke floor, native-width model fields, and pressure-sized cursor
are absent. This is not a promise of pressure-free native PencilKit drawing.

Nib, paper, line style, template, template-line style, appearance, page-color,
and scenery menus show explicit checkmarks and selected accessibility values.
Previously saved non-preset nib widths are preserved as checked Custom values.

Final local build `1.0.3` / `1012` on macOS 27.2 (26B123) passed:

- 68 XCTest unit/integration tests, zero failures.
- 260 native editor, 399 workspace, 31 equation, 12 ruled-text, and 8 shortcut checks.
  Workspace coverage includes each requested nib's actual nominal rendered width,
  Fine on tool selection, custom-width preservation, and the navigation cases below.
- Store/backup integration and 16 signed-updater configuration checks.
- ARM64 iPad simulator compilation and all 164 existing native checks, using fresh
  isolated notes. The dedicated simulator was shut down afterward.
- Read-only DMG verification, strict nested ad hoc signatures, ARM64/resources,
  original theme-image hashes, and mounted-app persistence checks.
- Local appcast generation and five valid/tampered update-signature cases.

Live Mac QA used a separate `io.inotes.nibqa` identity and temporary notes. The
first menu implementation used checkmark images in `Label`; macOS omitted them
from the rendered menu despite successful compilation. The final helper uses
native `Toggle` menu state, and screenshots confirmed visible checks for Fine,
Extra Fine after selection, dotted paper, solid line style, no template, solid
template line, system appearance, matching page colors, and Classic scenery.
Pen/Pencil menus showed 0.3/0.45/0.7/1 mm, and Brush showed 0.5/0.7/1/1.5 mm;
switching tools restored their respective checked Fine preset. `AGENTS.md` records
the native-menu trap. Native cursor regressions passed; this final pass does not
claim a new physical Pencil/tablet test or a displayed-system-cursor capture.

Reproduce packaging with
`VERSION=1.0.3 BUILD_NUMBER=1012 bash scripts/build-macos.sh`.
The app contains 29,583,429 regular-file bytes; the DMG contains 24,618,283 bytes
(23.48 MiB), SHA-256
`e3798d9ec557f91a610b5f6104159505f1bd35895911538542a9bc6bf2be5151`.
Temporary logs and the source hash manifest are under
`/private/tmp/inotes-nib-validation/`. This is a local candidate on the development
branch; version defaults and the public release remain 1.0.2. No new security scan,
Apple notarization, or public updater publication is claimed for this candidate.

### Navigation regression method

The stable outer detail container now owns the navigation probe; changing the
sheet-keyed editor no longer dismantles that probe or restores old open-pane state.
The editor's separate sheet identity remains necessary for undo isolation.
Regression sequences switch A → B → A with the sidebar hidden, both panes hidden,
and full-page mode. They sample frame positions and native collapse changes
throughout each transition, rather than checking only final state.

Native pane animations own their geometry. The tests sample presentation layers
for normal sheets-pane hide/show and require intermediate positions without
backtracking. Saved pane widths are restored after completion only when necessary.
Native full-page, rapid reversal, nil selection, teardown, and replacement-owner
cases are also covered. Passive waits must not force layout or click the page.
An earlier fixture's forced layout during animation startup made a hide assertion
unreliable; bounded passive geometry waits replaced that narrow wait.

The optimized full-app fixture exposed queued AppKit collapse work executing after
probe removal. Direct restoration, zero-duration animation, and disabling an item's
default collapse animation were insufficient alone, despite an isolated probe
passing. The fix keeps restoration owned by the controller through outstanding
native completions, then releases it. Successor probes wait for that restoration
before claiming the controller. `AGENTS.md` records the ownership and fixture traps.

## Withdrawn pressure trial — commit `085aab6`

This was a local experiment, not the current implementation or a public release.
It added Mac pressure boosting, iPad completed-stroke width floors, and portable
native-width metadata. Its 79 core, 279 editor, 351 workspace, and 197 iPad checks
passed, as did [hosted Native checks](https://github.com/icode100/iNotes/actions/runs/41307360271).
The user physically confirmed thickness changes and a dot cursor on the Deco 640,
then explicitly withdrew the pressure feature and requested the previous writing
behavior. The pressure implementation and its tests were reverted; navigation
fixes were retained. Later requests reintroduced Extra Fine with exact millimetre
presets, without restoring the pressure experiment. Do not reuse the withdrawn
trial's counts or artifact checksum as current validation.

A temporary hover probe initially produced misleading cursor captures: it used
the wrong hit-test coordinate space and the chat window was above the QA app at
the pointer. Those images did not establish a cursor regression. `AGENTS.md`
retains this lesson alongside the v0.2.2 cursor invariants.

## Earlier sidebar reflow candidate — 1.0.3 at `f1ae7ef`

On 1 November 2026, live QA reproduced the reported v1.0.2 sidebar bug:
with sheets hidden, closing the notebook sidebar left a 190-point blank gutter
until another interaction triggered layout. The background probe did not reliably
receive layout when its ancestor's native sidebar animated. The fix observes
the split's resize notifications and sidebar collapse state, then coalesces a
geometry-only inset refresh without forcing layout or replacing the editor.

The new regression uses the native animated `toggleSidebar` action followed by
passive run-loop waits. It neither forces layout nor clicks the page before
asserting geometry. Against the old production code, it failed with the editor
still at x=190 after both navigation panes closed. Against the fix, all eight
hide/show transitions passed: sheets visible/hidden in Text/Pen modes, retaining
editor identity, caret, page content, undo history, magnification, and cursor/input
ownership. The earlier fixture's repeated `layoutSubtreeIfNeeded()` calls had
masked the bug; `AGENTS.md` records this pitfall and the required regression method.

The final ARM64 candidate (`VERSION=1.0.3 BUILD_NUMBER=1010`) passed:

- 68 XCTest unit/integration tests, zero failures.
- 260 editor, 251 workspace, 31 equation, 12 ruled-text, and 8 shortcut checks.
- Storage/backup integration and 16 signed-updater configuration checks.
- Read-only DMG verification, strict nested ad hoc signatures, ARM64/resources,
  checksum, and mounted-app persistence smoke tests; the mount was removed.

Live checks used a separate `io.inotes.layoutqa` app identity, the packaged
production binary, temporary notes, Forest dark scenery, and Pen selected.
Screenshots taken immediately after toolbar sidebar hide/show showed aligned
heading/tools/page edges with sheets both hidden and visible, without any page
click between the action and observation. Production notes and the installed app
were untouched. Native cursor regressions passed; this pass did not repeat
physical tablet/Pencil testing or actual system-cursor image capture. Production
editor/input code is unchanged. All runtime checks ran on macOS 27.2 (26B123).

This is a local candidate, not a published GitHub release. Build defaults remain
at the last published version. Reproduce it with
`VERSION=1.0.3 BUILD_NUMBER=1010 bash scripts/build-macos.sh`.
The app contains 29,409,093 regular-file bytes; the DMG contains 24,614,139 bytes
(23.47 MiB), SHA-256
`4d4e779d2dd0f8b2cf76ac9ba37e4fe3af79e5c11517a6a8b12f1467721af601`.
Temporary logs are under `/private/tmp/inotes-sidebar-validation/`, including
`baseline-native.log`, `fixed-native.log`, `core-tests.log`, `release-build.log`,
`dmg-verification.log`, and `packaged-native-checks.log`. No new security scan,
notarization, iPad runtime test, or public updater publication is claimed.

## Version 1.0.2 sheet navigation validation

The local ARM64 build 1009 passed all 68 core tests with both XCTest and the
standalone runner. The final packaged app passed 260 editor, 187 workspace,
31 equation, 12 ruled-text, and 8 shortcut checks, plus storage/backup and
16 signed-update configuration checks on macOS 27.2. The iPad ARM64 simulator
target compiled with the final shared UI and passed 164 native checks using
fresh isolated notes. These counts describe executed tests, not physical stylus coverage.

New core cases cover optional sheet titles, stable numbering per chapter/topic,
legacy migration, invalid dates, Trash/deletion, cross-parent moves, duplication,
imports, overflow, and rejection of numbering/creation-date tampering. Workspace
checks cover independent heading/sheets controls, native collapse observation,
retained editor identity/caret/undo/zoom/cursor, and restored pane widths. Live QA
found a macOS underlay bug when the middle pane closed; the regression test now
checks the actual editor viewport stays beside the visible sidebar. Four badge
checks hit-test the real view hierarchy and confirm ink receives pointer events
through the sheet-number badge with tools shown or hidden.

Live isolated Mac checks created an untitled Sheet 3, typed literal `Typing check pbh`,
switched back to Pen, hid the heading/sheets independently, and inspected the
final full-page badge. Alpine dark and Forest light/dark cards and themed tool
selection were visually inspected. Native fixtures also retained a 170-point
pane across sheet selection and three hide/show cycles. CUA drag attempts did
not yield a reliable resize result; divider sizing/collapse was verified through
native APIs, accessibility width adjustment, and toolbar buttons. This pass did
not repeat physical tablet/Pencil pressure, tilt, hover, or a system-cursor capture;
the existing cursor behavior and native cursor regression checks are retained.

The mounted DMG passed strict nested signatures, ARM64/resource/icon checks,
and persistence smoke tests. Local feed/archive Ed25519 verification and all
five update-signature cases passed. The app contains 29,404,773 regular-file
bytes (28.04 MiB); the DMG is 24,607,259 bytes (23.47 MiB).
Evidence is under `/private/tmp/inotes-102-validation/` and
`/private/tmp/inotes-102-geometry/`; core logs are
`/private/tmp/inotes-v102-core-tests.log` and `/private/tmp/inotes-v102-standalone.log`.
The security scan described under v1.0.0 remains the historical scan record;
these v1.0.2 tests are not a new repository security scan or dependency CVE audit.

### 1.0.2 published release verification

Published [v1.0.2](https://github.com/icode100/iNotes/releases/tag/v1.0.2) is build
1009 from source commit `0522a3f2f2e34c809f405ad862fdfeda09cd1d28`. Both
[Native checks](https://github.com/icode100/iNotes/actions/runs/41291512021) and
[Signed macOS release](https://github.com/icode100/iNotes/actions/runs/41291897346)
passed, including hosted iPad compilation and release signing-key cleanup.

The independently downloaded public DMG matched its published SHA-256 checksum.
CryptoKit verified the feed and archive Ed25519 signatures against the committed
public key. At verification, the latest-release feed was byte-identical to the
versioned feed and identified version 1.0.2/build 1009 with the correct DMG URL.
Read-only mounted verification passed strict nested app signatures, ARM64
architecture, all six original scenery image hashes, adaptive icons, math
fonts/licenses, updater configuration, and persistence smoke checks.

The published app passed 259 editor, 187 workspace, 31 equation, 8 shortcut,
and 12 ruled-text checks on macOS 27.2 (26B123), plus storage/backup integration
and 16 signed-update configuration checks. These are the public binary's actual
counts; the local SDK build above ran 260 editor checks. The 187 workspace checks
include editor/cursor retention and pointer pass-through at the sheet-number badge.
This does not add physical stylus or system-cursor-capture coverage beyond the
limitations recorded above. The app remains ad hoc signed and is not Apple notarized.

The public DMG is 24,301,018 bytes (23.18 MiB), with SHA-256
`1c6c966ff35660bc35e162eafb89ae77dfca9a3e8c8540a5c89b44aeb9788bad`.
Its app contains 29,129,477 regular-file bytes (27.78 MiB). Evidence is under
`/private/tmp/inotes-102-release/`, including `public-native-checks.log`,
`public-runtime-verification.log`, `public-signatures.log`, and
`public-bundle-metadata.json`. Both read-only mounts were cleanly removed;
verification used isolated temporary libraries and left the installed app and
production notes unchanged. Temporary evidence files are not release assets.

## Version 1.0.1 photographic themes validation

The local ARM64 build 1008 passed all 63 XCTest unit/integration tests, 260 native
editor checks, 74 workspace checks, 31 equation checks, 12 ruled-text checks,
8 shortcut checks, and storage/backup/updater integration diagnostics. The new
workspace checks decode all six photographs and switch between every scenery
and appearance while retaining page content, native editor identity, zoom, and
pen cursor ownership. Production cursor/event handling is unchanged.

The iPad ARM64 simulator build passed 164 native checks on an isolated iPad Pro
M5 simulator. All six bundled PNGs matched the supplied originals byte for byte
in both the iPad app and mounted Mac DMG. The DMG also passed strict signatures,
architecture, resources, smoke tests, signed-feed/archive verification, and all
five update-signature cases.

Live Mac UI inspection switched Coast, Forest, and Alpine through both Light
and Dark using the Appearance menu in an isolated QA copy of the final app.
Each supplied photograph appeared in the navigation panes and heading, with
legible foreground text and unchanged vintage paper and note content. This
pass did not repeat physical tablet/Pencil testing or the system-cursor capture
probe; the native cursor regression checks passed.

The app contains 29,101,205 file bytes (27.75 MiB); the DMG is 24,482,447 bytes
(23.35 MiB). Build, native, simulator, package, and signature logs are under
`/private/tmp/inotes-photo-validation/`. These results describe the local build;
the separately built public release was verified as follows.

### 1.0.1 published release verification

Published [v1.0.1](https://github.com/icode100/iNotes/releases/tag/v1.0.1) is build
1008 from source commit `167cbfedc2ddcb870486bde5a88b0c0cc7ed11fc`. Both
[Native checks](https://github.com/icode100/iNotes/actions/runs/41283315422) and
[Signed macOS release](https://github.com/icode100/iNotes/actions/runs/41283724610)
passed, including hosted iPad compilation and release signing-key cleanup.

The independently downloaded public DMG matched its published SHA-256 checksum.
CryptoKit verified the feed and archive Ed25519 signatures against the committed
public key. The latest-release feed was byte-identical to the versioned feed and
identified version 1.0.1/build 1008 with the correct download URL. Read-only
mounted verification passed strict nested app signatures, ARM64 architecture,
all six original image hashes, icon variants, resources, and store/backup checks.
The public app passed 259 editor, 31 equation, 8 shortcut, 12 ruled-text, and
74 workspace checks. The hosted SDK runs one fewer editor check than the local
SDK. The app remains ad hoc signed and is not Apple notarized.

The public DMG is 24,208,570 bytes (23.09 MiB), with SHA-256
`8d56a6a3c5584f548d54d69ff3509562789e47e9a799f398ce9022b6d41c50c1`.
Its app contains 28,811,269 regular-file bytes (27.48 MiB). Evidence is under
`/private/tmp/inotes-photo-release/`; verification used temporary diagnostic
libraries and did not modify the installed app or production notes.

## Version 1.0.0 validation

The local ARM64 release candidate passed 63 XCTest unit/integration tests and
260 packaged native editor checks, 31 equation checks, 12 ruled-text checks,
8 tool-shortcut checks, and 46 full-workspace checks. The workspace suite mounts
the actual three-column UI and verifies full-page/toolbar restoration, native
editor identity, typing undo/redo, caret and zoom preservation, pen cursor
ownership, read-only Trash controls, and empty-selection recovery. Storage,
backup, and signed-updater configuration diagnostics also passed.

The iPad ARM64 simulator target compiled on the installed iOS 27.2 SDK and passed
148 native checks on an isolated iPad Pro M5 simulator. New checks cover centered
zoom, patterned lines and native round trips, templates, vintage paper, geometry
rejection, and bounded paper rendering. Physical Apple Pencil/tablet pressure,
tilt, and palm rejection still require hardware testing.

Live Mac UI checks exercised full-page hiding of both navigation panes, centered
25% zoom, global vintage paper, Alpine scenery, persisted dashed lines and
center-divider templates, and literal typing of `pbh` in Text mode. Native
diagnostics use temporary libraries; live QA uses separate app identities and
temporary note folders. No production notes are used as test fixtures.

Actual system-cursor captures from the user-authorized native hover probe showed
Pen (9×9), Pencil (8×8), and Marker (14×14) dot tips and a Highlighter (24×24)
slanted tip. Text mode showed the I-beam and accepted literal `pbh` typing.
Pen retained its dot after full-page and toolbar hide/restore, including at 25%
zoom. These sizes are logical image dimensions; Retina images have larger pixel
dimensions. Evidence is in `/private/tmp/inotes-v1-hover/request-202` through
`request-210` JSON/PNG captures (206 was superseded, not counted). The probe is
temporary QA code and is not included in the production application.

The Codex Security standard scan reviewed all 78 tracked files at `965306f` and
reported one low-severity patterned-ink rendering exhaustion issue. The release
fix adds a shared aggregate rendering budget and a defensive Mac renderer check.
Regression cases reject compact malicious dotted paths through archive,
clipboard, and atomic model updates while accepting ordinary patterned tables.
The final 63-test suite and native bitmap rejection check passed after this fix.
This is static source review plus regression testing, not a dependency CVE scan
or proof that all possible vulnerabilities are absent.

Local build and check logs are under `/private/tmp/inotes-v1-validation/`.

## Automated checks

Run from the repository root:

```sh
bash scripts/test.sh
bash scripts/build-macos.sh
bash scripts/verify-macos.sh
```

Tests belong to `Tests/NotesCoreTests`. `scripts/test.sh` probes for XCTest. With
full Xcode it uses SwiftPM XCTest; with Apple's Command Line Tools it compiles the
same test methods with a small dependency-free assertion adapter and prints
each result plus test/failure counts. Unexpected probe failures stop the script.
Both backends return a failure status when assertions fail. They exercise the
shared model and local persistence without requiring UI automation or a signed-in
cloud account. The GitHub workflow repeats tests, packages the app, verifies its
mounted DMG, and compiles the iPad simulator target. A workflow file is not
evidence that a hosted run has occurred.

The packaged app's `--smoke-test` checks the shared model and store integration,
including versioned backup writes, final save on quit, failed-save restart
protection and retry, and 16 signed-update configuration checks. Both packaging
scripts run this check. To additionally exercise native editor layout,
formatting, undo, ink rendering, and export with access to the Mac window server,
use:

```sh
dist/iNotes.app/Contents/MacOS/iNotes --smoke-test --editor-test
```

Editor diagnostics need a logged-in graphical Mac session and may require approval
when run from a restricted tool environment. Keep these opt-in so the normal
packaging smoke test can run without GUI access.

After building a DMG, prepare its signed appcast with the project's existing
signing identity and run the update-signature checks:

```sh
bash scripts/generate-appcast.sh
bash scripts/test-update-signatures.sh
```

These commands prepare and verify local artifacts; they do not publish a release.
The signature checks use CryptoKit independently of Sparkle to accept the valid
feed/archive pair and reject a changed feed, unsigned feed, changed archive, and
wrong public key. See [update setup](UPDATES.md) for signing and publishing.

The app's native text view uses platform undo and editing behavior. Canvas
gestures, tablet pressure, Apple Pencil, accessibility, cloud provider delivery,
and installer interaction need the device checks below; model tests cannot prove
those behaviors.

## Recorded results — 31 October 2026

Local host: Apple silicon ARM64, macOS 27.2 (26B123), Apple Swift 6.4.2, full
Xcode 27.2 (27B52). Hosted workflows use the `macos-26` runner; the recorded
0.1.x hosted runs used Xcode 26.6.

### 0.2.2 local cursor and production validation

The second live candidate fixes the observed ink-tool hover cursor by disabling
native body/textbox editing and selection while an ink tool is selected. Text
mode restores native editing; double-clicking a movable text box selects Text.
The preceding page/clip-only candidate still showed the I-beam.

- Actual toolbar clicks selected Pen, Pencil, Marker, and Highlighter. A
  user-approved native hover probe moved the pointer with `CGWarpMouseCursorPosition`
  and queued mouse-moved events in the app's own `NSApp` event queue. It did not
  change system permissions; external event posting was denied by TCC.
- The trace recorded the actual `NSCursor.currentSystem` tip for each tool:
  Pen 9×9, Pencil 8×8, Marker 14×14, and Highlighter 24×24 pixels. Captures of the
  system cursor were visually checked as three dot tips and a chisel tip.
- Selecting Text and sending real keyboard input `pbh` produced the literal
  text `Cursor typing check: pbh`.

Evidence: `/private/tmp/inotes-cursor-live/candidate2-trace.log` and the
`system-pen`, `system-pencil`, `system-marker`, and `system-highlighter` cursor
captures in the same directory. Clean production validation follows. Physical
tablet pressure/tilt and physical stylus hover remain unverified.

The final clean production build, 0.2.2 build 6, passed all 50 XCTest tests with
zero failures (0.709 seconds). Its app bundle passed 195 native editor checks,
31 equation checks, 8 shortcut checks, 12 ruled-layout checks, 16 updater
configuration checks, and store/backup integration checks. The mounted DMG
passed strict signatures, ARM64 architecture, and resource verification. The
production source and app contain no temporary diagnostic probes.

A clean QA app used the same compiled production code in an isolated app copy
with a separate bundle ID and test-library configuration. Actual keyboard input
typed `z` in Text, selected Pen, then used Command-Z to remove `z`, Command-Shift-Z to
restore it, and Command-Z to remove it again. A user-approved native pointer
warp over this app, followed by actual keyboard undo, retained the 9×9 system
Pen cursor; its captured dot was visually verified in
`/private/tmp/inotes-cursor-release/final-system-cursor.png`.

The first edit of the loaded fixture normalized a Core Text font fallback for
the `⌘` glyph from Helvetica Neue to Lucida Grande; the body text and ink stayed
unchanged. Repeated undo from that normalized baseline restored exact page
content and RTF, verified by comparing `ui-before-normalized.json` with the QA
library's saved `Library.json`. This does not establish byte-identical imported
RTF after the first edit.

Final local evidence: `/private/tmp/inotes-cursor-release/build.log`,
`/private/tmp/inotes-cursor-release/tests.log`,
`/private/tmp/inotes-cursor-release/native.log`, and
`/private/tmp/inotes-cursor-release/verify.log`.

### 0.2.2 hosted release verification

| Check | Result |
| --- | --- |
| Hosted Native checks | Passed [run 41223696128](https://github.com/icode100/iNotes/actions/runs/41223696128) at source revision [`2b3a354`](https://github.com/icode100/iNotes/commit/2b3a3543b15c072b67efd6eaf9a2d001ed91c80b), including iPad simulator compilation |
| Signed release workflow | Passed [run 41223698546](https://github.com/icode100/iNotes/actions/runs/41223698546) for [v0.2.2](https://github.com/icode100/iNotes/releases/tag/v0.2.2) |
| Public feed and archive | Independently downloaded v0.2.2 build 1006; CryptoKit verified both Ed25519 signatures against the committed public key, and the DMG SHA-256 matched the published checksum. At verification time, the latest-release appcast was byte-identical to the versioned feed and identified 0.2.2 / 1006 |
| Public installer | Passed strict app/framework signatures, ARM64 architecture, resources, read-only DMG mounting, and store/backup checks using `verify-macos.sh` |
| Published native app | Passed `--smoke-test --editor-test` from the mounted public app: 194 native editor checks, 31 equation checks, 8 shortcut checks, 12 ruled-layout checks, 16 updater-configuration checks, and store/backup integration checks. The published SDK 26 build runs 194 editor checks; the local SDK 27 build runs 195 because one existing check is SDK-conditional |

The public **0.2.2 build 1006** DMG is **5,073,284 bytes** (about 4.84 MiB),
with SHA-256
`712d918248a922265b86b7cf24a9f8ac719454cf44cc6ed6066b77454b7d4716`.
These are public artifact measurements, separate from local build 6.
Evidence: `/private/tmp/inotes-published-022/signature.log`,
`/private/tmp/inotes-published-022/verify.log`, and
`/private/tmp/inotes-published-022/native.log`. Physical tablet pressure/tilt
and physical stylus hover remain unverified.

### 0.2.1 cursor regression validation

**Failed cursor fix in 0.2.1:** after testing the new local 0.2.1 build,
the user confirmed that both mouse and tablet still showed an I-beam with an
ink tool selected. The native callback checks below passed, but they did not
establish the cursor shown during actual use. Live evidence for the subsequent
0.2.2 candidate is recorded above.

The native body and movable text boxes could restore an I-beam after selecting
an ink tool. This build added selected-tool cursor providers, ink tracking, and
same-tool refresh intended to address that behavior. Clipped/offscreen cursor
handling and Text-mode behavior were covered by the direct callback fixtures;
these fixtures did not catch the remaining live cursor failure in 0.2.1.

- Local build 5 passed all 50 XCTest tests with zero failures (0.738 seconds).
- The packaged Mac app passed 159 native editor checks, including 31 new cursor
  regressions: late body/textbox updates, all ink tools, canvas entry, stationary
  reselection, width/zoom changes, viewport clipping, and return to Text. It also
  passed 31 equation, 8 shortcut, 12 ruled-layout, 16 updater-configuration checks,
  and store/backup integration checks.
- Cursor tests inspect `NSCursor.current` after native view callbacks. The
  offscreen-window fixture supplies a key-window/pointer position for stationary
  checks without activating the app or moving the physical pointer. This is
  native regression coverage, not a physical stylus hover test.
- CI and release workflows now run the native editor suite after packaging, so
  these cursor regressions must pass before a release is published.
- The local ARM64 DMG passed read-only mounting, strict signatures, resource
  checks, checksum validation, and mounted-app persistence/backup checks.

Evidence: `/private/tmp/inotes-cursor-tests.log` and
`/private/tmp/inotes-cursor-native.log`.

### 0.2.1 hosted release verification

| Check | Result |
| --- | --- |
| Hosted Native checks | Passed [run 41200356265](https://github.com/icode100/iNotes/actions/runs/41200356265) at source revision [`f159330`](https://github.com/icode100/iNotes/commit/f159330926aa3ca6a3830812e67e47326757e0c9): shared tests, Mac packaging, native cursor/editor checks, mounted-DMG verification, and iPad simulator compilation |
| Signed release workflow | Passed [run 41200686415](https://github.com/icode100/iNotes/actions/runs/41200686415). Workflow success does not resolve the user-reported cursor issue above |
| Public assets | Independent public-asset verification has not been recorded |

### 0.2.0 local feature validation

| Check | Result |
| --- | --- |
| Shared model and persistence XCTest | Passed: 50 tests, 0 failures, 0.699 seconds. Coverage includes legacy archives and format 2 page objects, Unicode/equation search, mixed-selection geometry, validated clipboard payloads, independent folder backups, versioning, recovery, and size limits |
| iPad native editor integration | Passed: 98 checks in a fresh source-snapshot build on the iPad Pro 11-inch (M5), iPadOS 27.2 ARM64 simulator, using native `PKCanvasView`, `UITextView`, glyph layout, first responders, and undo managers. Coverage includes mixed text/ink/equation selection, rectangle/lasso geometry, body-text promotion, group movement and atomic undo/redo, native masks/colors/identities, clipboard bounds and sample budgets, fixed-width page reach, ruled baselines, and light/dark preservation |
| iPad input routing and shortcuts | Passed within the 98 native checks: Text routes finger/pointer and Pencil-typed input to native text, including blank margins and movable text boxes; it retains keyboard focus and hides the ink picker. Pen routes Pencil-typed input to the canvas. Re-selecting Text recovers focus, ordinary letters remain text in Text mode, and modified tool shortcuts remain available. The route tests supply the public helper's input-type parameter; they do not generate physical Pencil touches |
| iPad native typing undo/redo | Passed in light and dark modes: a real first-responder `UITextView` received Unicode through `insertText` and the persistence delegate; native undo/redo preserved typing history and restored exact canonical RTF. Isolated typing fixtures left the original page text/RTF unchanged |
| Independent automatic backups | Passed disposable-folder integration: both destinations write complete archives, restore folder bookmarks, back up on normal quit, retry a repaired target, and disconnect independently. Google Drive backup continues while the iCloud target is unavailable. Four shared backup tests also preserve handwriting, movable text, and equations |
| Bookmark fallback and relaunch | Passed using the production access helper in an isolated signed app: forced scoped-bookmark failure selects a marked ordinary bookmark only for a verified non-sandboxed Mac process; a separate fresh process restores it and writes the fixture folder. Legacy raw scoped bookmarks also restore. Sandboxed/error-unknown processes retain the strict scoped path |
| Live Mac Text/Pen routing | Passed with a Deco640 tablet connected: all alphabetic letters entered native text in Text mode, Command-Option-P selected Pen, and mouse input produced ink. Physical stylus pressure/tilt was not exercised by this check |
| Live ruled-paper appearance | Passed visual checks of text baselines against 28-point rules in light and dark appearances, alongside handwriting and rendered equations. Native iPad checks also verify wrapped Unicode, heading metrics, movable-box origins, empty typing, and unchanged canonical RTF |
| Native Mac app suites | Passed in the app bundle: 128 editor checks, 31 equation checks, 8 shortcut checks, 12 ruled-layout checks, store/backup checks, and 16 signed-update configuration checks |
| Live Mac typing undo/redo | Passed actual keyboard input: typing `z`, Command-Z, and Command-Shift-Z restored the expected text and exact canonical RTF/page-content fields. This covers real menu/key dispatch in addition to direct native-manager operations |
| Final Mac candidate UI | Passed in the proper candidate app: Search followed by re-selecting Text restored keyboard entry; `vlpbhet` typed literally with the Deco640 connected. Command-Option-P selected Pen and the plain `H` shortcut selected Highlighter. Light/dark ruled pages were visually checked, and a dark-page highlighter stroke retained canonical gold ink with the existing body intact. Actual `z` → Command-Z → Command-Shift-Z preserved exact page content/RTF |
| Final 0.2.0 installer and signatures | Passed ARM64 packaging, strict app/framework/helper signatures, read-only mounted DMG, Applications link, and mounted-app smoke checks. All five signature probes passed: valid signed feed/archive accepted; changed feed, unsigned feed, changed archive, and wrong public key rejected |

Current evidence is recorded in `/private/tmp/inotes-features-xctest.log`,
`/private/tmp/inotes-features-ipad-build.log`,
`/private/tmp/inotes-features-ipad-diagnostics.json`, and
`/private/tmp/inotes-bookmark-fallback-proof.log`. Final Mac package evidence is
in `/private/tmp/inotes-features-release-final-native.log`,
`/private/tmp/inotes-features-release-final-verify.log`, and
`/private/tmp/inotes-features-release-final-signatures.log`.

The verified **local 0.2.0 build 4** app contains 9,347,377 bytes of files
(8.91 MiB). Its DMG is 5,367,174 bytes (5.12 MiB), with SHA-256
`af227bdf6c94cf5b8e8ef205036fd39a10704b9b7675186e63df8ed6211d1986`.
These are local candidate measurements. Folder writes were tested locally;
actual iCloud Drive and Google Drive upload completion has not been verified.
Artifact sizes do not measure RAM.

### 0.2.0 hosted release verification

| Check | Result |
| --- | --- |
| Signed macOS release workflow | Passed [run 41198905582](https://github.com/icode100/iNotes/actions/runs/41198905582) at source revision [`608ebb7`](https://github.com/icode100/iNotes/commit/608ebb732f518a7a1b2d962492863754055958dc), publishing [v0.2.0](https://github.com/icode100/iNotes/releases/tag/v0.2.0) |
| Hosted Native checks | Passed [run 41198904250](https://github.com/icode100/iNotes/actions/runs/41198904250) at source revision `608ebb7`: shared tests, ARM64 packaging, mounted-DMG verification, and iPad simulator compilation |
| Public release assets | Passed independent download of [v0.2.0 assets](https://github.com/icode100/iNotes/releases/tag/v0.2.0): CryptoKit verified the build 1004 appcast and DMG Ed25519 signatures against the committed public key; the DMG matched its published SHA-256 checksum. At that verification time, the default `/releases/latest/download/appcast.xml` was byte-identical to the verified v0.2.0 feed |
| Mounted public installer | Passed independent public-DMG mount, checksum, strict app/framework/helper signatures, ARM64 verification, native icon/font resources, and store/backup smoke checks |
| Published Mac app runtime | Passed the published SDK 26 app on macOS 27.2: 127 editor checks, 31 equation checks, 8 shortcut checks, 12 ruled-layout checks, 16 updater configuration checks, and store/backup integration. The local SDK 27 app passed 128 editor checks; SDK-specific coverage accounts for the count difference |

The independently downloaded **published 0.2.0 build 1004** DMG is 5,048,113 bytes
(4.81 MiB), with SHA-256
`43143c6321eb5ae3dd54588ac36ccf18d0c35adc9e84f18d9c9d3bb112c03e65`.
The verified public appcast SHA-256 is
`44d1386b5b4b0a1863870a65e3a881099cc2d402099fd5f0a7784ee5568da927`.
The published app's native runtime log is
`/private/tmp/inotes-published-020/native-editor.log`.

### 0.1.x release validation history

| Check | Result |
| --- | --- |
| Shared model and persistence XCTest | Passed through `scripts/test.sh`: 34 tests, 0 failures, including legacy archives, instrument/paper persistence, size limits, recovery, conflict checks, theme contrast, palette conversion, custom-color handling, and unchanged archived ink |
| Native macOS debug compilation | Passed using SwiftPM's native build system and isolated scratch directory |
| App `--smoke-test` | Passed: save, reopen, archive import, versioned folder backup, oversized-update rejection, final save on quit, 16 signed-update configuration checks, and failed-save restart protection/retry after repairing storage |
| iPad project metadata | Passed plist/XML checks; shared app/editor sources are registered in the target |
| Native AppKit editor integration | Passed: 87 checks covering the shared text/ink page, straight lines and axis snapping, instruments, long pages, RTF/Unicode/formatting, undo/redo, pressure, eraser, combined PNG/PDF export, PencilKit interchange, light/dark rendering, canonical rich-text colors, theme-only changes without saves, and bounded dirty-rectangle drawing |
| Local app and DMG | Passed for local 0.1.0 build 2 and 0.1.2 build 3 ARM64 artifacts: local signature, property list, checksum, read-only mounted image, Applications link, and mounted-app smoke checks. Local 0.1.2 Mac and iPad compilation also passed |
| iPad simulator compilation | Passed with full Xcode: `iNotes-iPad` scheme, iPadOS simulator SDK, signing disabled; no source compile errors |
| iPad simulator launch, themes, and persistence | Passed on a fresh iPad Pro 11-inch (M5), iPadOS 27.2 ARM64 simulator: install, launch, relaunch, unchanged saved library, and live switches in both light/dark directions with the shared page and native tool palette |
| iPad native editor integration | Passed: 32 opt-in DEBUG checks against a real simulator `PKCanvasView` and native `UndoManager`, covering straight lines, snapping, pressure, per-gesture undo/redo, portable pen conversion, stronger paper guides, adaptive ink, custom-color restoration, theme changes without persistence, and canonical storage of new dark-page strokes |
| Adaptive app icons | Passed: native Aqua and Dark Aqua icon stacks are present in packaged assets, light/dark pencil icons were visually inspected, and the ICNS fallback is bundled for older macOS versions |
| Sparkle security and signature probes | Passed review of macOS-only pinned Sparkle, embedded ARM64 helpers/framework signatures and RPATH, HTTPS/public-key configuration, signed-feed enforcement, verification before extraction, disabled unsigned-feed expiry fallback, and ignored private-key permissions. All five final signature probes passed: valid feed/archive accepted; changed feed, unsigned feed, changed archive, and wrong public key rejected |
| HID metadata and false positives | Read-only enumeration worked without opening devices; the built-in trackpad's digitizer usage 5 is excluded from pen-tablet detection |
| Live Mac unified-page walkthrough | Passed: new sheet, Unicode rich text, pencil underline while text stayed visible, persisted grid paper, translucent highlighter, ink undo preserving text/paper, and truthful mouse/pen status; persisted JSON was checked |
| Live Mac paper and ink themes | Passed all six combinations of light/dark with grid, ruled, and dotted paper. Guides remained visible, existing text/ink adapted, theme-only switches left saved archive bytes unchanged, and newly drawn dark-page strokes retained canonical stored colors |
| Tracking/menu/export live regression | Passed in the corrected release: More menu opened and tracked safely, plain-text export opened the native save panel, UTF-8 bullets/keyboard symbols saved to the correct `.txt` file, and the app remained running with no new crash report |
| Straight-line live Mac check | Passed: horizontal and vertical lines persisted as exact two-endpoint strokes alongside unchanged typed text and grid paper |
| Local header alignment | Passed in local 0.1.2 build 3 in light and dark appearances: star and More icons share a centerline, the redundant menu chevron is hidden, and spacing is comfortable. Favorite toggling updates the filled star and list marker; the complete More menu remains functional |
| Hosted GitHub CI | Passed final [Native checks run 41189630063](https://github.com/icode100/iNotes/actions/runs/41189630063) at source revision `924508c`: unit/integration tests, ARM64 packaging, mounted-DMG verification, and iPad simulator compilation. Earlier [run 41189297677](https://github.com/icode100/iNotes/actions/runs/41189297677) at `559eeea` also passed |
| Hosted signed release | Passed final [release run 41189632342](https://github.com/icode100/iNotes/actions/runs/41189632342) at source revision `924508c`, publishing [v0.1.2 build 1003](https://github.com/icode100/iNotes/releases/tag/v0.1.2) after package and signature checks. Earlier [v0.1.1 release run 41189300121](https://github.com/icode100/iNotes/actions/runs/41189300121) at `559eeea` also passed |
| Public release download verification | Passed after independently downloading [v0.1.1](https://github.com/icode100/iNotes/releases/tag/v0.1.1) and [v0.1.2 assets](https://github.com/icode100/iNotes/releases/tag/v0.1.2): CryptoKit validated both public appcast/DMG signature pairs against the committed public key, and both DMGs matched their published SHA-256 checksums. At that verification time, the default `/releases/latest/download/appcast.xml` feed was byte-identical to the verified v0.1.2 feed |
| Native public-feed update check | Passed using an isolated, unchanged local 0.1.0 build 2: Sparkle contacted the public GitHub feed and displayed that iNotes 0.1.1 was available for the installed 0.1.0. The dialog was closed through Close/Dismiss; no update was downloaded or installed |

The historical **local 0.1.0 build 2** app contains 6,675,198 bytes of files
(6.37 MiB), including
1,378,628 bytes (1.31 MiB) for Sparkle. These logical file counts exclude duplicate
symlink targets. Its compressed DMG is 4,225,365 bytes (4.03 MiB), with SHA-256
`4c20db3e9715b14de5d8125dbe14aef205dd3260fcaebcdc8ec7f1a3f0b538b3`.

The **local 0.1.2 build 3** app contains 6,729,790 bytes of files (6.42 MiB), and
its compressed DMG is 4,235,934 bytes (4.04 MiB), with SHA-256
`bafcc7bf5bbdf823c09eccbd7c993368f5adbdbf8f7f6468494612ee55b3871b`.
These measurements identify local artifacts; use the checksum asset attached to
each published release for that download. Artifact sizes do not measure RAM.

The independently downloaded **published 0.1.2 build 1003** DMG is 4,054,708 bytes
(3.87 MiB), with SHA-256
`f31bd94e2eac5389f01cf8aa09bfc83cb2ab99290f470378c403212887e44f40`.

The backup smoke test used a temporary local folder to validate archive creation
and contents. It did not upload through a Google account. iPadOS compilation,
simulator launch/relaunch, native editor diagnostics, and visual rendering were
verified. Gesture diagnostics commit strokes through the app's pipeline
programmatically; they do not generate physical Pencil touches. Manual simulator
gesture and physical Apple Pencil tests remain outstanding.

Theme-suite output is recorded in `/private/tmp/inotes-theme-tests.log` and
`/private/tmp/inotes-theme-core-tests.log`. iPad theme build/runtime results are
recorded in `/private/tmp/inotes-ipad-theme-build.log`,
`/private/tmp/inotes-ipad-theme-validation.log`, and
`/private/tmp/inotes-ipad-theme-diagnostics.json`; screenshots of both appearances
are `/private/tmp/inotes-ipad-light-page.png` and
`/private/tmp/inotes-ipad-dark-page.png`. These session files are temporary and
are not included in the release.

To repeat the iPad native diagnostics on a temporary simulator, launch the
Debug build with `SIMCTL_CHILD_INOTES_IOS_EDITOR_DIAGNOSTICS=1`; the app writes
`Library/Caches/iNotesEditorDiagnostics.json` in its data container, then restores
the original drawing. The diagnostic is absent from release builds.

The same page keeps text, handwriting, movable text boxes, equations, and its
paper background together. In 0.2.0, Text routes pointer/finger/stylus input to
native text and caret entry, including native Scribble where enabled by iPadOS;
the drawing tools route stylus input to ink. The layers stay visible on one
zoomed document. Physical pen pressure, palm rejection, and Apple Pencil/Scribble
hardware have not been validated on this host.

## Required manual checks before public release

Record device model, OS version, app commit, result, and any issue for every run.

| Area | Procedure | Acceptance |
| --- | --- | --- |
| Installer | Open the DMG, drag to Applications, eject, launch the copied app | Launches from Applications without requiring mounted DMG |
| Upgrade | Create notes, quit, replace app with newer version, relaunch | Existing notes and hierarchy remain available |
| Hierarchy | Create workbook, chapter, nested topic, sheets; rename and move | Selection and hierarchy persist across relaunch |
| Editing | Type Unicode, paste styled text, format, undo and redo; switch sheets | Saved text and formatting survive relaunch |
| Ink | Draw curves and straight lines; change instrument/width/color; erase and undo | No dropped strokes or edits leaking to another sheet |
| Straight Line tool | Draw horizontal/vertical table borders and arbitrary-angle lines; undo and redo each gesture | One two-endpoint line per gesture; directions within 8° snap to exact axes; one undo removes one line and redo restores it |
| Page themes | Switch both appearances with grid, ruled, and dotted paper; draw, type, edit, undo, and relaunch | Paper guides and ink remain legible; appearance alone does not alter saved content; new edits keep their intended colors |
| Signed updates | Install an older test build, serve a valid newer signed feed/DMG, and complete an update with saved and deliberately unsavable test notes | Valid updates preserve notes; failed saves keep the app open; unsigned/tampered feeds or archives are rejected; a repaired save can retry |
| Tablet | Use physical pressure-sensitive tablet on Mac | Strokes track pen and pressure; normal clicks remain usable |
| iPad | Build with Xcode and test on physical Apple silicon iPad | Navigation, rotation, split view, keyboard and persistence work |
| Apple Pencil | Draw with palm resting on iPad; use tool picker and undo | Pencil input remains smooth and palm does not add marks |
| Backup | Export archive, import into a fresh test library | Content, hierarchy, attachments and drawings match |
| Recovery | Preserve a test copy, corrupt its JSON, relaunch | Error is visible and original corrupt data is not overwritten |
| Drive | Save backup into a user-selected Google Drive folder; inspect another device | Archive arrives intact and imports successfully |
| Offline | Disconnect network, edit, back up, reconnect Drive | Local editing continues and provider eventually uploads backup |
| Accessibility | VoiceOver, keyboard navigation, Increase Contrast, text selection | Controls have useful labels and no keyboard traps |
| Performance | Time launch and profile memory with small and large libraries | Record measurements, not unverified claims |
| Older OS | Repeat core workflow on macOS 14 and later supported OS versions | No missing API crash or document damage |

## Compatibility status

Build and device results are recorded in the root README or the change report.
Deployment targets declare intended minimums; they do not establish compatibility
with every intermediate OS version. Unless explicitly recorded as passed, assume
physical stylus pressure/tilt, palm rejection, physical iPad/Apple Pencil, cloud
upload completion, Gatekeeper on a second Mac, and older macOS checks remain
unverified. Deco640 connection and keyboard/mouse routing were checked as
recorded above. Hosted CI and release verification are recorded by version
above, including the independently verified public v0.2.2 artifacts. The native
public-feed check stopped at the available-update
dialog. Update download, installation, and relaunch from an older installed app
remain unverified.

Use temporary test libraries for destructive recovery tests. Keep independent
exports of real notes. The separate iCloud Drive and Google Drive targets write
versioned archives through the selected Finder/Files folder. Their providers
handle uploading; importing an archive transfers its notes. Folder backups do
not merge concurrent edits between devices.
