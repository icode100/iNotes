# iNotes

A small, native, open-source notebook for Apple silicon Macs, with a shared iPad app target. Built with SwiftUI, AppKit/UIKit, and PencilKit. No Electron, web view, third-party runtime, account, or telemetry.

## What works

- Workbooks → chapters → nested topics → sheets, with renaming, moving, duplication, and recoverable Trash.
- Text and handwriting share one scrollable, zoomable page. Select Text, pen, straight line, pencil, marker, highlighter, or eraser without hiding either text or ink. Native rich text includes headings, formatting, lists, links, spell checking, and undo/redo.
- Straight-line pen tool for table borders, with near-horizontal/vertical snapping and Shift axis constraints on Mac.
- Pressure-aware pen-tablet input on Mac, including stylus proximity and hardware eraser events. Read-only HID presence detection excludes touchpads; the input indicator confirms actual pen activity. No global input capture or tablet SDK is required.
- Apple Pencil and native PencilKit tools on iPad, with palm rejection and actual Pencil touch detection. Basic ink paths and instrument styles transfer between Mac and iPad; native PencilKit data is retained. Grid, ruled, dotted, and blank paper save with each sheet.
- Search across titles, text, and tags; favorite sheets; embedded file attachments.
- Automatic local saves, a previous-version backup, explicit damaged-library recovery, and external-change checks that prevent overwriting another app instance's changes.
- Portable `.inotes` import/export. Import creates a separate copy; it never replaces existing notebooks.
- Mac text/RTF export and combined-page PDF/PNG export, preserving text and ink together. Files/Google Drive export on iPad.
- Google Drive folder backups on Mac, including delayed backups after edits and a final backup on normal quit. No cloud SDK or OAuth secret is needed.
- ARM64 `.app` and drag-to-Applications `.dmg` packaging, with verification scripts.

## Run on Mac

Requires an Apple silicon Mac and macOS 14+. Build tools: Apple Command Line Tools with Swift 6+, or full Xcode. The application itself has no developer-tool requirement.

```sh
./scripts/test.sh
./scripts/build-macos.sh
./scripts/verify-macos.sh
open dist/iNotes.app
```

The installer is `dist/iNotes-0.1.0-arm64.dmg`. Open it and drag iNotes into Applications. Local builds use ad hoc signing. Public distribution requires Developer ID signing and Apple notarization; see [build instructions](docs/BUILD.md).

## iPad

Open `iNotes.xcodeproj` in full Xcode, select the **iNotes-iPad** scheme, set your development team, and build for an iPad simulator or physical iPad running iPadOS 17+. The target compiles for the iPad simulator and is included as source; no signed iPad installer is distributed here. Physical-device and Apple Pencil validation are still required before an iPad release.

## Google Drive

1. Install Google Drive for desktop and sign in.
2. In iNotes, open **Backups → Connect Google Drive folder…** and choose a folder inside My Drive.
3. iNotes creates timestamped `.inotes` files in an `iNotes Backups` subfolder. After changes, automatic backups occur at most once per minute. **Back up to Drive now** writes immediately. Drive for desktop handles the upload.
4. To transfer a notebook to another device, import a backup. On iPad, export through Files and choose the Google Drive location.

This is versioned backup and manual transfer, not automatic multi-device edit merging. iNotes cannot confirm that Google has uploaded a file. Backups are retained until you remove them. A connected folder may also be a local, external-drive, or other cloud-provider folder. Google documents [Finder access and offline behavior](https://support.google.com/drive/answer/13401938?hl=en).

## Data and recovery

The local library is `~/Library/Application Support/iNotes/Library.json`; the previous saved version is `Library.previous.json`. Use **File → Show Library in Finder**. A malformed primary library is kept intact and saves pause. If a valid previous version exists, **Backups → Recover previous local version…** preserves the damaged file before restoring it. Always keep independent exported backups.

The portable library format is versioned JSON with embedded rich text, pen data, and attachments. Individual attachments are limited to 10 MiB and the entire archive to 64 MiB. This intentionally bounded first release targets personal notebooks, not multi-gigabyte OneNote libraries. Text and attachment contents are saved locally in readable form; device storage protection is provided by macOS/iPadOS.

## Scope and compatibility

iNotes is an independent notebook inspired by OneNote's organization, not a complete implementation of Microsoft OneNote or its file format. `.one`/`.onepkg` import, Microsoft sync, live collaboration, OCR/handwriting recognition, audio/video recording, equations, multiple freely positioned text containers, and automatic conflict merging are not implemented. Mac ink and PencilKit share basic paths; advanced PencilKit tools can render differently on Mac.

Validated results and outstanding hardware/cloud checks are recorded in [testing](docs/TESTING.md). Physical pen pressure, palm rejection, every supported macOS version, iPad builds, and Google upload completion must be verified on the corresponding devices/services. Native ARM64 packaging does not itself establish M1–M5 hardware coverage.

## Project layout

`Sources/NotesCore` contains the platform-independent model, archive format, and persistence. `Sources/NotesApp` contains the shared UI and native editors. `Tests/NotesCoreTests` contains unit and integration tests; on Command Line Tools installations without XCTest, the same methods run through the standalone assertion runner. `--smoke-test` additionally runs store, persistence, and backup checks in temporary libraries. Add `--editor-test` in a graphical Mac session for native rich-text, drawing, and PencilKit interchange checks.

Contributions are welcome. Run the test and packaging scripts before proposing changes. See [MIT license](LICENSE).
