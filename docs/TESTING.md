# Validation

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
with a separate bundle ID and test-library configuration. Actual keyboard input typed `z` in
Text, selected Pen, then used Command-Z to remove `z`, Command-Shift-Z to
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
`/private/tmp/inotes-cursor-release/verify.log`. Hosted CI and public-release
verification for 0.2.2 are pending.

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
recorded above. Hosted CI and v0.1.1/v0.1.2/v0.2.0 publication passed as recorded
above. The native public-feed check stopped at the available-update
dialog. Update download, installation, and relaunch from an older installed app
remain unverified.

Use temporary test libraries for destructive recovery tests. Keep independent
exports of real notes. The separate iCloud Drive and Google Drive targets write
versioned archives through the selected Finder/Files folder. Their providers
handle uploading; importing an archive transfers its notes. Folder backups do
not merge concurrent edits between devices.
