# iNotes

Version 1.0 introduces full-page writing, centered zoom, patterned straight lines, paper templates, vintage pages, and scenic workspace themes. Version 1.0.1 uses the supplied Coast, Forest, and Alpine photographs with matching light/dark variants.

A small, native, open-source notebook for Apple silicon Macs, with a shared iPad app target. Built with SwiftUI, AppKit/UIKit, and PencilKit, with Sparkle for signed Mac updates and SwiftMath for offline equations. No Electron, cloud SDK, account, or telemetry.

## What works

- Workbooks → chapters → nested topics → sheets, with distinct sidebar icons, renaming, moving, duplication, and recoverable Trash. Create workbooks using **New workbook** in the sidebar.
- Text and handwriting share one scrollable, zoomable page. Select Text, pen, straight line, pencil, marker, highlighter, or eraser without hiding either text or ink. Native rich text includes headings, formatting, lists, links, spell checking, and undo/redo.
- **Text** routes every pointer, including a pen tablet or Apple Pencil, to the text caret and text selection. Choose a drawing tool for handwriting. Typing in Text mode keeps ordinary letters as text.
- **Select** draws a rectangular selection; **Lasso** follows a freehand outline. Select typed text, pen strokes, positioned text boxes, and equations together, then move, copy, cut, paste, duplicate, delete, or undo the selection. Moving or pasting selected typed text creates a positioned rich-text box on the same paper.
- Editable LaTeX equations with a native live preview, fractions, roots, powers, Greek symbols, sums, integrals, and matrices. Equations share the page with text and handwriting and adapt to light/dark paper. Rendering uses the pinned, open-source SwiftMath 1.7.3 library entirely on the device.
- Straight-line pen tool for table borders, with near-horizontal/vertical snapping and Shift axis constraints on Mac.
- Mac pen and pencil cursors show a nib dot sized for the selected width and page zoom. The highlighter uses a slanted chisel-tip cursor.
- Pressure-aware pen-tablet input on Mac, including stylus proximity and hardware eraser events. Read-only HID presence detection excludes touchpads; the input indicator confirms actual pen activity. No global input capture or tablet SDK is required.
- Apple Pencil and native PencilKit tools on iPad, with palm rejection and actual Pencil touch detection. Basic ink paths and instrument styles transfer between Mac and iPad; native PencilKit data is retained. Grid, ruled, dotted, and blank paper save with each sheet.
- Ruled paper aligns typed baselines with its guides, including wrapped paragraphs, headings, and moved text boxes. The native layout follows whole ruled rows while preserving saved rich-text formatting and colors.
- Light, dark, and system appearance for the shared page, readable ink colors, and prominent grids, rules, and dots. Switching appearance preserves original note colors. The single-pencil app icon includes native light and dark appearances.
- Search across titles, text, positioned text boxes, equation source, and tags; favorite sheets; embedded file attachments.
- Automatic local saves, a previous-version backup, explicit damaged-library recovery, and external-change checks that prevent overwriting another app instance's changes.
- Portable `.inotes` import/export. Import creates a separate copy; it never replaces existing notebooks.
- Mac text/RTF export includes canonical typed text, positioned text, and LaTeX source. Combined-page PDF/PNG export preserves rendered text, ink, text boxes, and equations together. Files export on iPad.
- Independent automatic iCloud Drive and Google Drive folder backups, including delayed backups after edits, retries after failed writes, and a final backup on normal Mac quit. Connect both folders to keep Google Drive backups running when the iCloud folder is unavailable. No CloudKit database, cloud SDK, or OAuth secret is needed.
- ARM64 `.app` and drag-to-Applications `.dmg` packaging, with verification scripts.
- Native Mac update checks, verified Ed25519 downloads, and installation on quit. Release tags publish a signed feed through GitHub Releases after the signing secret is configured; see [release setup](docs/UPDATES.md).

## Tool shortcuts

These keys switch tools when the page has drawing/selection focus. While editing
text, use **⌘⌥** with the listed key; keep **Shift** for Pencil and Straight Line.
The modified shortcuts also work with an iPad hardware keyboard. Letters typed
in notes, titles, search, or the equation editor remain text.

| Tool | Page key |
| --- | --- |
| Select | V |
| Lasso | L |
| Pen | P |
| Pencil | Shift+P |
| Brush / Marker | B |
| Highlighter | H |
| Eraser | E |
| Text | T |
| Straight Line | Shift+L |

## Run on Mac

Requires an Apple silicon Mac and macOS 14+. Building the installer requires full Xcode 26+ for its adaptive light/dark icon. The application itself has no developer-tool requirement.

```sh
./scripts/test.sh
./scripts/build-macos.sh
./scripts/verify-macos.sh
open dist/iNotes.app
```

The default local installer is `dist/iNotes-1.0.1-arm64.dmg` (version 1.0.1, build 1008). Downloaded public builds are also ad hoc signed: **they are not Apple notarized**, so macOS may report that Apple could not verify iNotes is free of malware.

If you trust the download from the [official releases](https://github.com/icode100/iNotes/releases), follow Apple's [per-app first-open procedure](https://support.apple.com/en-us/102445):

1. Open the DMG, drag **iNotes** into **Applications**, and open that installed copy.
2. If macOS blocks it, dismiss the warning and open **System Settings → Privacy & Security**. Find the iNotes warning under Security and click **Open Anyway**.
3. Confirm **Open** when prompted and authenticate if requested. This creates an exception for this app.

The updater's Ed25519 signatures verify release authenticity and integrity; they do not provide Apple Developer ID signing, notarization, or an Apple malware assessment. See [build instructions](docs/BUILD.md) for notarized distribution setup.

## iPad

Open `iNotes.xcodeproj` in full Xcode, select the **iNotes-iPad** scheme, set your development team, and build for an iPad simulator or physical iPad running iPadOS 17+. The target compiles for the iPad simulator and is included as source; no signed iPad installer is distributed here. Physical-device and Apple Pencil validation are still required before an iPad release.

## Automatic folder backups

1. Enable iCloud Drive or install and sign into Google Drive for desktop. On iPad, enable the provider's location in Files.
2. In iNotes, open **Automatic backups**, choose **iCloud Drive** or **Google Drive**, and select **Connect folder…**. Choose a folder belonging to that provider. Connect each destination separately if you want both.
3. iNotes writes timestamped `.inotes` archives inside an `iNotes Backups` subfolder. After edits, automatic backups occur at most once per minute; **Back up now** writes immediately. A failed destination retries while the app remains open. Google backups continue independently when the iCloud destination fails.
4. The cloud provider handles uploading. To bring notes to another device, import a completed backup; import adds a separate notebook copy. Some iPad providers may require reconnecting their folder after restarting.

Backups are retained until you remove them. A successful folder write confirms a local/provider write; it does not confirm a completed cloud upload. The app does not use CloudKit or automatically merge edits from multiple devices. A connected folder can also be on a local or external drive. Google documents [Finder access and offline behavior](https://support.google.com/drive/answer/13401938?hl=en).

## Data and recovery

The local library is `~/Library/Application Support/iNotes/Library.json`; the previous saved version is `Library.previous.json`. Use **File → Show Library in Finder**. A malformed primary library is kept intact and saves pause. If a valid previous version exists, **Backups → Recover previous local version…** preserves the damaged file before restoring it. Always keep independent exported backups.

The portable library format is versioned JSON with embedded rich text, pen data, positioned text boxes, editable LaTeX source, and attachments. Format 2 reads legacy format 1 libraries; adding positioned content upgrades a legacy library to format 2. Older apps reject the new format, protecting new page content from being silently discarded. The attachment picker accepts individual files up to 10 MiB. Archive imports use a 64 MiB aggregate limit, including embedded attachments, rather than a separate per-attachment limit. This intentionally bounded release targets personal notebooks, not multi-gigabyte OneNote libraries. Text and attachment contents are saved locally in readable form; device storage protection is provided by macOS/iPadOS.

## Scope and compatibility

iNotes is an independent notebook inspired by OneNote's organization, not a complete implementation of Microsoft OneNote or its file format. `.one`/`.onepkg` import, Microsoft sync, live collaboration, OCR/handwriting recognition, audio/video recording, and automatic conflict merging are not implemented. Mac ink and PencilKit share basic paths; advanced PencilKit tools can render differently on Mac. The equation editor supports common LaTeX math syntax rather than full TeX documents, document packages, or arbitrary macros; unsupported expressions report an error. Source is limited to 16,384 characters, 64 nested groups, and 256 commands per equation.

Validated results and outstanding hardware/cloud checks are recorded in [testing](docs/TESTING.md). Physical pen pressure, palm rejection, every supported macOS version, physical iPad behavior, and actual iCloud/Google upload completion must be verified on the corresponding devices/services. Native ARM64 packaging does not itself establish M1–M5 hardware coverage.

## Project layout

`Sources/NotesCore` contains the platform-independent model, archive format, and persistence. `Sources/NotesApp` contains the shared UI and native editors. `Tests/NotesCoreTests` contains unit and integration tests; on Command Line Tools installations without XCTest, the same methods run through the standalone assertion runner. `--smoke-test` additionally runs store, persistence, and backup checks in temporary libraries. Add `--editor-test` in a graphical Mac session for native rich-text, drawing, equation rendering, and PencilKit interchange checks.

Contributions are welcome. Run the test and packaging scripts before proposing changes. See [MIT license](LICENSE).
