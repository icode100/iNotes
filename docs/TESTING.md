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
Xcode 27.2 (27B52). Hosted runs below used the `macos-26` runner and Xcode 26.6.

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
| Public release download verification | Passed after independently downloading [v0.1.1](https://github.com/icode100/iNotes/releases/tag/v0.1.1) and [v0.1.2 assets](https://github.com/icode100/iNotes/releases/tag/v0.1.2): CryptoKit validated both public appcast/DMG signature pairs against the committed public key, and both DMGs matched their published SHA-256 checksums. The default `/releases/latest/download/appcast.xml` feed was byte-identical to the verified v0.1.2 feed |
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
physical tablet, physical iPad, Apple Pencil, cloud upload, Gatekeeper on a second Mac, and
older macOS checks remain unverified. Hosted CI and v0.1.1/v0.1.2 publication passed as
recorded above. The native public-feed check stopped at the available-update
dialog. Update download, installation, and relaunch from an older installed app
remain unverified.

Use temporary test libraries for destructive recovery tests. Keep independent
exports of real notes. Google Drive folder backup relies on the user's installed
Drive client or Files provider; it is not a real-time multi-writer sync protocol.
