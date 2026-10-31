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
including versioned backup writes and final save on quit. Both packaging scripts
run this check. To additionally exercise native editor layout, formatting, undo,
ink rendering, and export with access to the Mac window server, use:

```sh
dist/iNotes.app/Contents/MacOS/iNotes --smoke-test --editor-test
```

Editor diagnostics need a logged-in graphical Mac session and may require approval
when run from a restricted tool environment. Keep these opt-in so the normal
packaging smoke test can run without GUI access.

The app's native text view uses platform undo and editing behavior. Canvas
gestures, tablet pressure, Apple Pencil, accessibility, cloud provider delivery,
and installer interaction need the device checks below; model tests cannot prove
those behaviors.

## Recorded results — 31 October 2026

Host: Apple silicon ARM64, macOS 27.2 (26B123), Apple Swift 6.4.2, full Xcode 27.2
(27B52).

| Check | Result |
| --- | --- |
| Shared model and persistence XCTest | Passed through `scripts/test.sh`: 29 tests, 0 failures, 0.725 seconds, including legacy archives, instrument/paper persistence, size limits, recovery, and conflict checks |
| Native macOS debug compilation | Passed using SwiftPM's native build system and isolated scratch directory |
| App `--smoke-test` | Passed: save, reopen, archive import, versioned folder backup, oversized-update rejection, and final save on quit |
| iPad project metadata | Passed plist/XML checks; all 12 app/editor Swift files are registered in the target |
| Native AppKit editor integration | Passed in rebuilt release app: 69 checks covering safe tracking/menu event classification, the shared text/ink page, straight lines with axis snapping, long-page sizing, instruments, grid, RTF, Unicode, formatting, undo/redo, pressure, eraser, combined PNG/PDF export, and PencilKit interchange |
| Release app and DMG | Passed: ARM64 release build, local signature, property list, compressed-image checksum, read-only mounted image, Applications link, and mounted app smoke test |
| iPad simulator compilation | Passed with full Xcode: `iNotes-iPad` scheme, iPadOS simulator SDK, signing disabled; no source compile errors |
| iPad simulator launch and persistence | Passed on a fresh iPad Pro 11-inch (M5), iPadOS 27.2 ARM64 simulator: install, launch, relaunch, unchanged saved library, and visual rendering of the shared text/ink page with the native tool palette |
| iPad straight-line and undo integration | Passed: 14 opt-in DEBUG checks against a real simulator `PKCanvasView` and native `UndoManager`, covering two-endpoint lines, axis snapping, pressure, separate gesture undo/redo, and portable pen conversion |
| HID metadata and false positives | Read-only enumeration worked without opening devices; the built-in trackpad's digitizer usage 5 is excluded from pen-tablet detection |
| Live Mac unified-page walkthrough | Passed: new sheet, Unicode rich text, pencil underline while text stayed visible, persisted grid paper, translucent highlighter, ink undo preserving text/paper, and truthful mouse/pen status; persisted JSON was checked |
| Tracking/menu/export live regression | Passed in the corrected release: More menu opened and tracked safely, plain-text export opened the native save panel, UTF-8 bullets/keyboard symbols saved to the correct `.txt` file, and the app remained running with no new crash report |
| Straight-line live Mac check | Passed: horizontal and vertical lines persisted as exact two-endpoint strokes alongside unchanged typed text and grid paper |

The final release app contains 2,347,468 bytes of files (2.24 MiB); the compressed
DMG is 698,726 bytes (682.35 KiB). These are artifact sizes, not RAM measurements.
The DMG SHA-256 is `c7a33792b8615a1a3f8e841e87db1d6e106ed064ac1eabad5a227b5f20116d80`.

The backup smoke test used a temporary local folder to validate archive creation
and contents. It did not upload through a Google account. iPadOS compilation,
simulator launch/relaunch, and visual rendering were verified; simulator gestures
and physical Apple Pencil tests remain outstanding.
Core-suite output for this session was saved to `/tmp/inotes-tests.log`; packaging,
mounted-image verification, and iPad build logs are `/tmp/inotes-release.log`,
`/tmp/inotes-dmg-verify.log`, and `/tmp/inotes-ipad-build.log`.
The final native editor diagnostics are in `/tmp/inotes-editor-tests.log`.
The iPad runtime validation log is `/tmp/inotes-ipad-validation.log`.
The line diagnostic result is `/tmp/inotes-ipad-line-diagnostics.json`. This check
commits lines through the app's actual pipeline programmatically; it does not
generate physical Pencil touches. To repeat on a temporary simulator, launch the
Debug build with `SIMCTL_CHILD_INOTES_IOS_EDITOR_DIAGNOSTICS=1`; the app writes
`Library/Caches/iNotesEditorDiagnostics.json` in its data container, then restores
the original drawing. The diagnostic is absent from release builds.

The same page keeps text, handwriting, and its paper background together; the
Text tool changes input routing without hiding the ink. On iPad, a shared zoomed
document contains transparent native text and PencilKit layers. Pencil input goes
to PencilKit while finger/pointer input can edit text. Physical pen pressure,
palm rejection, and Apple Pencil hardware have not been validated on this host.

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
physical tablet, iPad, Apple Pencil, cloud upload, Gatekeeper on a second Mac, and
older macOS checks remain unverified.

Use temporary test libraries for destructive recovery tests. Keep independent
exports of real notes. Google Drive folder backup relies on the user's installed
Drive client or Files provider; it is not a real-time multi-writer sync protocol.
