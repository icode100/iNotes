# iNotes

**iNotes 1.4.2, build 2024**, released on 26 November 2026, lets you reveal
page navigation by moving the pointer to the bottom of the window or pin the
bar to keep it visible. Both modes work in a regular Mac window, in Full Page
and in macOS full screen. On iPad, tap the bottom handle to reveal the bar.
[Download the Apple silicon Mac installer](https://github.com/icode100/iNotes/releases/download/v1.4.2/iNotes-1.4.2-arm64.dmg)
or [read the release notes](https://github.com/icode100/iNotes/releases/tag/v1.4.2).

**iNotes 1.4.0, build 2022**, introduced numbered page navigation, topic
PDFs, workbook ZIP exports and a movable circular toolbar. It also added
connected diagram objects, resizable table cells, handwriting recoloring and
personal pen and paper defaults. [1.4.0 release notes](docs/releases/1.4.0.md)

**iNotes 1.3.0, build 2021** introduced Mac shapes, attached arrow connectors and
editable table cells. Published and independently verified on 6 November 2026.
Exact-source hosted Native checks, iPad compilation, signed release checks and
independent public-download verification passed. See the
[release notes](docs/releases/1.3.0.md) and [validation record](docs/TESTING.md).

Choose **Shapes and tables** in the toolbar and drag on the
page. Each placement returns to **Select**, ready to move or resize the object;
click blank paper to deselect. Pasted images also enter Select immediately.
Drag an arrow endpoint to reconnect it, or double-click a label/cell to edit its text.
The icon palette offers five
basic shapes, straight/elbow connectors, arrowheads, tinted fills and table
dimensions, with names on hover. Choose another icon or press **S** to arm the
next placement; **⌘⌥S** works while typing.
Diagram pages are read-only on iPad. The published 1.3.0 app writes archives
with diagrams in format 4 and also opens earlier formats.

The **v1.2 update (1.2.2, build 2020)** adds paper, ink, title and zoom changes:
scenery-matched paper, Vintage Black, Pitch Black/White, five pastel papers,
sixteen ink presets and a native custom color picker. New pages open blank
immediately; type in the underlined title at the top to name them, or leave it
empty. In v1.2, Mac pages opened fitted to the visible width. Command-Plus/Minus
zoom manually and View → Fit Page Width restores fitting.

The preceding Mac release was **1.2.2, build 2020**, published on 5 November 2026.
Exact-source Native checks passed on both branch and main, including iPad
compilation; signed release run 18 and independent downloaded-public-asset
verification also passed. See the [release notes](docs/releases/1.2.2.md) and
[validation record](docs/TESTING.md) for evidence and remaining limits.

The user passed the initial isolated 1.2.0 Mac QA app and authorized publication.
The unpublished [1.2.0](docs/releases/1.2.0.md) and
[1.2.1](docs/releases/1.2.1.md) attempts stopped during verification; their tags
and builds 2018/2019 remain preserved. The released version owns its Mac heading
controls and waits for native completion callbacks in diagnostics, retaining the
original geometry limits. This does not claim a runtime pane-policy fix or a new
manual QA pass.

Version 1.1.0 (v1.1), build 2017, introduced Arctic, Open Skyscape,
Ruby Hills, and Nature scenery, replaced Forest, and added Extra Broad nibs.
Coast and Alpine remain available. Extra Broad uses 1.5 mm for Pen, 1.3 mm for
Pencil and Straight Line, and 2 mm for Brush/Marker.

Its earlier results remain in the [v1.1 release notes](docs/releases/1.1.0.md)
and [validation history](docs/TESTING.md).

The existing fixes keep active pages numbered consecutively after
deletion, restoration, moves, and drag reordering. They also make **⌘A** select
the whole page from every tool.

A small, native, open-source notebook for Apple silicon Macs, with a shared iPad app target. Built with SwiftUI, AppKit/UIKit, and PencilKit, with Sparkle for signed Mac updates and SwiftMath for offline equations. No Electron, cloud SDK, account, or telemetry.

## Editing in iNotes 1.4

- **Float the toolbar.** Open **Appearance → Full-screen toolbar** and choose **Floating · always visible** or **Floating · show on hover**. Enter **Full Page** (⇧⌘F on Mac) or use the Mac window’s full-screen button. Drag the bubble to park it, then click it to open a circle of tools. In hover mode, move over the small **⋯** handle to reveal the bubble. Tap the handle on iPad. Click the center again to close the tools. The **More page tools** menu includes attachments and workspace controls.
- **Connect objects on Mac.** Hover over a shape, table, image, positioned text box, equation, or arrow and click the small **+**. Choose a shape or table to place it nearby with an attached arrow. Drag it below its parent and the arrow switches from the side edges to the parent’s bottom and the child’s top. On an existing arrow, **+** continues from its destination or connects its free end to the new object. Undo reverses the insertion in one step.
- **Edit an arrow on Mac.** Select one connector and click **Arrow**. Choose a straight or elbow route, arrowheads at the end or both ends, or no heads. Change the head style (open or filled), line pattern, width, and color, then click **Apply**. Drag either endpoint to the edge of a shape, table, image, positioned text box, or equation to reconnect it. Dragging an endpoint pins it to the chosen edge. For an arrow created in an earlier build, choose **Attachment sides → Automatic → Apply** to have its ends follow the layout.
- **Resize table cells on Mac.** Use **Select**, click a table, and drag an internal divider to give one row or column more room. The neighboring row or column shares the same space, and the outside edges stay put. Double-click a cell to edit its text.
- **Recolor handwriting on Mac or iPad.** Select the strokes with **Select** or **Lasso**. Choose a toolbar swatch, or open **Recolor ink** for more swatches and a custom color. Click **Apply** for a custom color. Recoloring edits just the selected ink, including when the selection also contains other objects. Undo restores the previous colors.
- **Set your defaults.** Open **Notebook defaults…** from **Appearance**. Set a preset or custom nib width and an optional starting color per drawing tool, including Shapes and arrows on Mac. Choose the paper, template, and template line for newly created pages. These preferences apply across workbooks on this device.

### Page navigation in 1.4.2

Move the pointer to the bottom edge of the notebook to reveal the page numbers,
page browser and **+** button. Click the pin on the bar to keep it in view, or
choose **Appearance → Page navigation → Pin to bottom**. Choose **Show on
hover** to return to the edge handle. The same setting applies in a regular
window, in Full Page and in macOS full screen. With touch, tap the handle.

### Per-page zoom in 1.5.0

Pages start at **100%**. In the bottom page bar, drag the slider or type
a percentage from **25% to 400%** and press Return. Choose **Fit Page** to see
the entire page or **Fit Width** to fill the available width. In a narrow window, click the percentage to open
the controls. Fitting adapts as the viewport changes.

iNotes remembers the zoom you choose for each page on this device, including
after reopening the app. Open **Appearance → Notebook defaults… → Default
zoom** and choose **Percentage** to type a starting value for pages without a saved zoom.

### Export a workbook as one PDF in 1.5.0

On Mac, right-click a workbook in the sidebar and choose **Export workbook as
single PDF…**, then choose where to save it. The PDF opens with the workbook
title, followed by a numbered divider for each chapter. Each topic and subtopic
gets a heading above its first note. PDF bookmarks follow the notebook hierarchy.
Choose **Export workbook as PDF bundle (ZIP)…** to save the separate folder PDFs.

### Full Page window controls in 1.5.0

When using Full Page in a regular Mac window, the red, yellow, and green
window buttons stay available. Open the floating toolbar and click its
inward-pointing arrows to return to the regular workspace. This also exits
macOS full screen when the window is in a full-screen Space.

## What works

- Numbered page dots at the bottom of the notebook switch pages. The adjacent **+** adds a blank page. **Browse pages** opens a searchable page list for finding and organizing notes. The drawing toolbar includes **Undo** and **Redo**.
- On Mac, open a folder’s context menu or the page’s **More page actions** menu to export a topic or chapter as one PDF. Each notebook page occupies one PDF page, even when it extends below the screen. Bookmarks follow nested topics. Choose **PDF bundle (ZIP)** for a workbook or topic to keep folders and subtopics as directories with separate PDFs. Choose the filename and destination in the save dialog.
- Workbooks → chapters → nested topics → pages, with distinct sidebar icons, renaming, moving, duplication, and recoverable Trash. Create workbooks using **New workbook** in the sidebar.
- Page numbers appear with creation dates in the page browser and header. Active pages are numbered consecutively within each chapter or topic and renumber after reordering, moving, deletion, and restoration. New pages open immediately with an empty underlined title. The breadcrumb identifies the containing chapter or topic.
- Text and handwriting share one scrollable, zoomable page. Select Text, pen, straight line, pencil, marker, highlighter, or eraser without hiding either text or ink. Native rich text includes headings, formatting, lists, links, spell checking, and undo/redo.
- **Text** routes every pointer, including a pen tablet or Apple Pencil, to the text caret and text selection. Choose a drawing tool for handwriting. Typing in Text mode keeps ordinary letters as text.
- **Select** draws a rectangular selection; **Lasso** follows a freehand outline. Select typed text, pen strokes, positioned text boxes, equations, images and diagrams together, then move, copy, cut, paste, duplicate, delete, or undo the selection. Moving or pasting selected typed text creates a positioned rich-text box on the same paper.
- On Mac, select an existing shape or table and choose **Fill → Filled** to tint it with its outline color, or **No fill** to clear it. You can change several shapes together. **Fill new shapes** in the Shapes palette sets the default for the next shape.
- **⌘A / Select All** from the page editor selects body text, ink, text boxes, equations, images and diagrams together with any tool selected. Search, title, and equation-source fields retain their own native Select All behavior.
- On Mac, paste a copied image or image file with **⌘V** into the open page, then write or draw over it with Text or the ink tools. Use **Select** to move an image, or drag its lower-right selection handle to resize it proportionally. Images and annotations can be selected and moved together; resizing an image alone leaves annotations independent. Images save with the page and appear in combined PDF/PNG exports. PNG, TIFF, JPEG, HEIC, GIF (first frame), and BMP clipboard images are accepted within the 10 MiB, 16-megapixel, and 8192-pixel-per-side limits. Image pasting is currently Mac-only.
- Editable LaTeX equations with a native live preview, fractions, roots, powers, Greek symbols, sums, integrals, and matrices. Equations share the page with text and handwriting and adapt to light/dark paper. Rendering uses the pinned, open-source SwiftMath 1.7.3 library entirely on the device.
- Straight-line pen tool for table borders, with near-horizontal/vertical snapping and Shift axis constraints on Mac.
- Mac pen and pencil cursors show a nib dot sized for the selected width and page zoom. The highlighter uses a slanted chisel-tip cursor.
- Fine is the factory starting width for each writing tool. The Extra Fine, Fine, Medium, Broad and Extra Broad nibs measure 0.3/0.45/0.7/1/1.5 mm for Pen, 0.3/0.45/0.7/1/1.3 mm for Pencil and Straight Line, and 0.5/0.7/1/1.5/2 mm for Brush (Marker). Highlighter has its own choices. Nib, paper, line, template, and theme menus show the selected choice, including custom saved nib widths.
- Pressure-aware pen-tablet input on Mac, including stylus proximity and hardware eraser events. Read-only HID presence detection excludes touchpads; the input indicator confirms actual pen activity. No global input capture or tablet SDK is required.
- Apple Pencil and native PencilKit tools on iPad, with palm rejection and actual Pencil touch detection. Basic ink paths and instrument styles transfer between Mac and iPad; native PencilKit data is retained. Grid, ruled, dotted, and blank paper save with each page.
- Ruled paper aligns typed baselines with its guides, including wrapped paragraphs, headings, and moved text boxes. The native layout follows whole ruled rows while preserving saved rich-text formatting and colors.
- Light, dark, and system appearance for the shared page, readable ink colors, and prominent grids, rules, and dots. Switching appearance preserves original note colors. The single-pencil app icon includes native light and dark appearances.
- Classic plus Coast, Alpine, Arctic, Open Skyscape, Ruby Hills, and Nature workspace scenery, with paired light/dark photographs. A saved Forest preference now shows Nature. The matching page-color choice follows scenery and appearance; explicit vintage, pitch and pastel papers stay fixed. Scenery never changes saved note content.
- Search across titles, text, positioned text boxes, equation source, diagram labels, table cells and tags; favorite pages; embedded file attachments.
- Automatic local saves, a previous-version backup, explicit damaged-library recovery, and external-change checks that prevent overwriting another app instance's changes.
- Portable `.inotes` import/export. Import creates a separate copy; it never replaces existing notebooks.
- Mac text/RTF export includes canonical typed text, positioned text, LaTeX source, diagram labels and table cells. Combined-page PDF/PNG export preserves rendered text, ink, text boxes, equations, images and diagrams together. Files export on iPad.
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
| Shapes and tables (Mac) | S |

## Run on Mac

Requires an Apple silicon Mac and macOS 14+. Building the installer requires full Xcode 26+ for its adaptive light/dark icon. The application itself has no developer-tool requirement.

```sh
./scripts/test.sh
./scripts/build-macos.sh
./scripts/verify-macos.sh
open dist/iNotes.app
```

The public installer uses version 1.4.2, build 2024. The packaging defaults for this checkout use 1.5.0, build 2025. Unpublished versions 1.2.0/build 2018, 1.2.1/build 2019 and 1.4.1/build 2023 stay reserved. Downloaded public builds use ad hoc signing without Apple notarization, so macOS may report that Apple could not verify iNotes is free of malware.

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
3. iNotes writes timestamped `.inotes` archives inside an `iNotes Backups/Automatic-…` subfolder belonging to this local library. After edits, automatic backups occur at most once per minute; **Back up now** runs immediately. Identical copies are skipped. A failed destination retries while the app remains open. Google backups continue independently when the iCloud destination fails.
4. The cloud provider handles uploading. To bring notes to another device, import a completed backup; import adds a separate notebook copy. Some iPad providers may require reconnecting their folder after restarting.

Automatic backups and **Back up now** use a rotating history: the latest 5 copies,
up to one per UTC day for 7 days and one per UTC week for 4 weeks (at most 16
distinct copies), within a 500 MiB budget per local library and destination.
The budget removes older recovery points first. Cleanup runs only after a current
archive is read back and verified, and keeps the two newest valid copies. Files
that cannot be safely checked or removed are kept with a warning; these can leave
the folder above its budget. Other installations' history and unrecognized files
are excluded. **Export library backup…** creates an independent permanent copy.

Backups made by earlier versions stay in the original `iNotes Backups` folder.
Choose **Automatic backups → [destination] → Review older backups…** to inspect
their dates and sizes, select unwanted copies and confirm deletion. These older
files may include manual or other-device backups; none are selected automatically.
The two newest valid older copies are protected, and a current managed backup is
verified before cleanup. Large folders are reviewed in bounded batches. Deletions
may also be synchronized by the cloud provider.

A successful folder write confirms a local/provider write; it does not confirm a completed cloud upload. The app does not use CloudKit or automatically merge edits from multiple devices. A connected folder can also be on a local or external drive. Google documents [Finder access and offline behavior](https://support.google.com/drive/answer/13401938?hl=en).

## Data and recovery

The local library is `~/Library/Application Support/iNotes/Library.json`; the previous saved version is `Library.previous.json`. Use **File → Show Library in Finder**. A malformed primary library is kept intact and saves pause. If a valid previous version exists, **Backups → Recover previous local version…** preserves the damaged file before restoring it. Always keep independent exported backups.

iNotes 1.4 reads library formats 1 through 5. New libraries start in format 2, which supports positioned text and equations. Adding an image requires format 3, and basic diagrams require format 4. Custom table row heights or column widths, open arrowheads, automatic attachment sides, and arrows attached to images, positioned text boxes or equations require format 5. Once a library uses format 5, opening it requires a format-5-capable build even if those objects are later removed. The iPad app opens pages containing images or diagrams read-only.

The attachment picker accepts files up to 10 MiB. A library archive can contain up to 64 MiB in total, including its attachments. Text and attachments are stored locally in readable form and rely on macOS or iPadOS for device storage protection.

## Scope and compatibility

iNotes is an independent notebook inspired by OneNote's organization, not a complete implementation of Microsoft OneNote or its file format. `.one`/`.onepkg` import, Microsoft sync, live collaboration, OCR/handwriting recognition, audio/video recording, and automatic conflict merging are not implemented. Mac ink and PencilKit share basic paths; advanced PencilKit tools can render differently on Mac. The equation editor supports common LaTeX math syntax rather than full TeX documents, document packages, or arbitrary macros; unsupported expressions report an error. Source is limited to 16,384 characters, 64 nested groups, and 256 commands per equation.

Validated results and outstanding hardware/cloud checks are recorded in [testing](docs/TESTING.md). Physical pen pressure, palm rejection, every supported macOS version, physical iPad behavior, and actual iCloud/Google upload completion must be verified on the corresponding devices/services. Native ARM64 packaging does not itself establish M1–M5 hardware coverage.

## Project layout

`Sources/NotesCore` contains the platform-independent model, archive format, and persistence. `Sources/NotesApp` contains the shared UI and native editors. `Tests/NotesCoreTests` contains unit and integration tests; on Command Line Tools installations without XCTest, the same methods run through the standalone assertion runner. `--smoke-test` additionally runs store, persistence, and backup checks in temporary libraries. Add `--editor-test` in a graphical Mac session for native rich-text, drawing, equation rendering, and PencilKit interchange checks.

Contributions are welcome. Run the test and packaging scripts before proposing changes. See [MIT license](LICENSE).
