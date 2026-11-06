# iNotes contributor guide

## Scope and evidence

iNotes is a lightweight, MIT-licensed native notebook for Apple silicon Macs,
with a shared iPad target. It is inspired by OneNote's organization; it does not
implement Microsoft's file format or every OneNote feature.

Read `README.md` for supported behavior, `docs/BUILD.md` for packaging,
`docs/UPDATES.md` for releases, and `docs/TESTING.md` for recorded verification.
Source and actual test results take precedence over plans or release-note drafts.
The v1.0.2 work adds optional sheet titles, stable per-folder sheet numbers,
creation metadata, independent pane controls, a workspace sheet-number badge,
and clearer themed controls/cards. Consult the versioned validation record before
claiming that a source change, local build, or separately built public release passed.

The published v1.1 update uses version **1.1.0**, build **2017** (release run 15),
from source `7946a931c8283e5fc0429fbd1d400f22d76312a5`. It replaces Forest with
Arctic, Open Skyscape, Ruby Hills, and Nature, while retaining Coast, Alpine,
and Classic. Existing `forest` scenery
preferences resolve to Nature. Extra Broad follows Broad: 1.3 mm for
Pencil and Straight Line, 1.5 mm for Pen, and 2 mm for Brush/Marker. The user
passed the local candidate QA, then requested the Pen-only increase on 4 November
2026. Exact-source Native checks, signed release run 15 and independent public
asset verification passed. The final numeric correction did not receive a
second manual QA pass; consult `docs/TESTING.md` for precise evidence and limits.

The **v1.2 update** adds scenery-matched page colors, Vintage Black,
Pitch Black/White, five pastel papers, sixteen preset ink colors and a native
custom color picker. New sheets open immediately with an empty stored title;
the underlined top title field names the sheet as the user types and can be
cleared again. Mac pages initially fit the visible editor width; explicit zoom
disables automatic fitting. Command-Plus/Minus zoom the existing Mac page and
View → Fit Page Width restores automatic fitting. The user passed the isolated
1.2.0 QA app and authorized publication on **5 November 2026**.

Unpublished 1.2.0/build 2018 failed heading restoration. The 1.2.1 source
`adf533e4f4ad190422111e531c8c038e72bbfbb6` replaces Mac title/tag inputs with
owned AppKit controls after passive tests captured incorrect native heights.
Outer SwiftUI frames alone retained native overflow. It passed the full local
suite and two exact-source hosted Native runs, including iPad compilation.
Signed release run **17**, build **2019**, then failed a pane-width assertion
while native exit generation 12 still had one pending completion. All 100 heading
cycles retained correct field heights. Mounted verification, Ed25519 probes and
publication were not reached; preserve both failed tags/build reservations.

Published **1.2.2 / build 2020**, source
`aa392994ed290e38819a74e0a21f5dad520642a3`, corrects the diagnostic's fixed
0.4-second settled-state assumption with bounded passive native-completion and
queued-callback observation. It retains geometry limits, first completed-state
failures and early motion evidence; production pane policy is unchanged.
Both exact-source Native runs (including iPad compilation), signed release run
**18**, and independent public-download verification passed on **5 November
2026**. Hosted checks recorded 126 core tests, 852 editor and 2,000 workspace
checks; consult `docs/TESTING.md` for complete evidence and limits. The public
installer, checksum and signed feed match the verified release bytes. Initial
manual QA applies to the earlier isolated 1.2.0 app; later heading/input and test
changes received native fixtures without a new physical IME/stylus or manual QA
claim. Preserve the failed 1.2.0 and 1.2.1 tags/build reservations.


The **1.3.0 candidate** adds native editable rectangles, rounded rectangles,
ellipses, triangles, diamonds, attached straight/elbow arrow connectors and
plain-text table cells on Mac. Diagram objects participate in the shared page's
selection, movement/resizing, snapshots, undo, clipboard and combined exports.
Diagram-bearing iPad pages show a native read-only preview and a Mac-only editing
notice. Current development defaults target prospective build **2021**, subject
to a fresh feed/counter check after publication approval. No 1.3 release or user
QA result is implied; consult the new validation record for actual checks.
Local checks passed 133 core tests, 964 editor checks (104 diagram), 2,000
workspace checks and the remaining native integration on 6 November 2026.
Earlier full runs stalled after the new fixture; a scoped autorelease-pool
boundary releases its native objects before the next suite. Preserve the failed
traces and strict assertions. Production pane policy was unchanged; no internal
AppKit mechanism, hosted/iPad compile, physical-device or user-QA pass is claimed.

The user tried the initial 1.3 QA app and requested placement UX changes on
6 November 2026. Successful image/diagram insertion now selects the new objects
and returns to Select immediately; blank clicks deselect without repeating the
shape. A shape icon or S arms the next single placement. Ordinary native text
paste and rejected transactions must preserve their tool/focus behavior. The
shape chooser is an icon palette with tooltips, visible checks and accessibility
names/selected values. QA build 2 uses a separate identity and an independent copy
of temporary QA notes; initial QA remains intact. Consult the follow-up validation
record for results specific to these changes. QA build 2 compiled and passed
119 diagram / 979 editor / 31 equation / 12 ruled-text / 9 shortcut checks, then
failed the same narrow-window native completion boundary despite released
fixture objects. Do not claim the autorelease pool fully resolves that issue,
a full follow-up pass, or release readiness. Preserve the strict five-second
boundary and failure trace; hosted/iPad and manual UX checks remain pending.

## Priorities

- Protect saved notes, archive compatibility, undo history, and recoverability.
- Preserve the v0.2.2 cursor fix; an ink tool must never retain the text I-beam.
- Keep typed text, handwriting, text boxes, and equations on the same page.
- Keep the app native and small; justify added dependencies and measure size.
- Treat Mac as the primary shipping target without breaking shared iPad sources.
- Report measured results and remaining limitations, especially physical stylus testing.

## Architecture and file ownership

- `Sources/NotesCore`: platform-independent Codable models, archive validation,
  persistence, backup archives, ink limits, selection geometry, and page themes.
  `PageDiagram.swift` owns portable shapes, connector anchors, tables and bounds.
- `Sources/NotesApp/NotesStore.swift`: observable library state, mutations,
  autosave, recovery, and independent cloud-folder backup scheduling.
- `ContentView.swift`, `SheetDetail.swift`, `WorkspaceAppearance.swift`: navigation,
  sheet UI, tools, themes, and workspace presentation. Keep layout changes here
  separate from drawing/input behavior unless the task requires both.
- `MacHeadingFields.swift`: owned Mac title/tag native controls and field-editor
  synchronization. Keep each control's role, actual font-derived height, native
  selection, marked text and field-local undo handling intact.
- `Editors/UnifiedPageEditor.swift`: shared Mac page using AppKit text and ink layers.
  `RichTextEditor.swift`, `MacPageObjects.swift`, and `MacPageSelection.swift`
  participate in native text, object, selection, undo, and cursor behavior.
  `MacPageDiagrams.swift` draws and edits diagrams; keep visible connector-label
  bounds shared by rendering, selection, lasso and double-click text editing.
- `Editors/UnifiedPageEditor+iOS.swift`: UIKit/PencilKit page and iPad diagnostics.
- `Tests/NotesCoreTests`: XCTest methods plus `StandaloneRunner.swift` for CLT-only hosts.
- `scripts/`: build, DMG verification, signing, and signature regression checks.
- `iNotes.xcodeproj`: iPad target; shared-source/resource changes may need target updates.

Deployment targets are macOS 14 and iPadOS 17. SwiftPM uses tools version 6.0
and Swift 5 language mode. Dependencies are pinned in `Package.swift` and
`Package.resolved`: Sparkle 2.10.1 on Mac only, and SwiftMath 1.7.3 for offline math.
Use availability guards for APIs newer than the deployment target.

## Model, hierarchy, and data safety

- Hierarchy: root workbooks → chapters → nested topics and sheets. Sheets have no children.
- Keep node IDs stable during normal edits. Imports remap IDs into separate copies;
  they must not overwrite existing notebooks. Duplication preserves page payloads.
- A sheet title may be empty; workbook/chapter/topic names must remain nonempty.
  Use `displayTitle` for visible/export fallbacks, not as a replacement stored title.
  New-sheet actions create blank sheets directly without a naming dialog. The
  underlined title field edits only `title`, preserving ID, creation metadata,
  page content, page order and sheet numbers. Keep an editing draft so trimming
  the stored title does not eat spaces mid-word; rejected renames must restore
  the saved value. Preserve the 256-character limit and field-local Select All.
- The user's 3 November 2026 sheet-numbering request supersedes the earlier
  lifetime-allocation rule. Active `sheetNumber` values are contiguous page
  numbers, starting at 1 within each immediate chapter/topic in saved page order.
  Removing Sheet 2 from 1, 2, 3 immediately makes the former Sheet 3 become 2;
  the next new sheet appends as 3. Removing all active sheets restarts at 1.
- Creation, Trash, restoration, permanent deletion, duplication, moves, and
  same-parent drag reordering must maintain that sequence. Dragging Sheet 3
  between 1 and 2 makes it Sheet 2 and the former Sheet 2 become 3. Renaming,
  content edits, and search do not change page order or numbers. Folder copies
  and whole-library imports have independent sequences under their new IDs.
- Trashed sheets are outside the active page sequence. Keep their stored
  numbers unique among all siblings and keep `lastSheetNumber` covering the
  stored maximum for older-reader compatibility. Neither archival Trash numbers
  nor this compatibility counter may create gaps in the active sequence.
  Restoring a sheet inserts it according to page order and normalizes the numbers.
- Legacy numbering migration first assigns missing numbers by `createdAt`, then
  UUID for ties; active numbers are then normalized by saved page order. Compact
  gaps in valid older numbered libraries on load too. Preserve stored array order,
  IDs, titles, timestamps, and all page payloads; reject nonfinite dates before
  sorting. Incidental renumbering must not recreate the native editor or rewrite
  content/creation metadata. Content edits alone must not change numbering.
- Archive format 4 reads formats 1, 2 and 3. Image/diagram-free new libraries
  default to format 2; positioned text/equations promote format 1 to 2, images
  promote to 3, and diagrams promote to 4. Never downgrade after removing newer
  objects. Older readers must reject format 4 rather than silently lose diagrams.
  Keep decoder defaults and legacy fixtures.
- Page images are canonical PNG objects behind text and ink. Preserve them in every
  page snapshot, undo operation, duplication/import, mixed clipboard payload and
  PDF/PNG export. Image-bearing iPad sheets are currently read-only with an explicit
  Mac-only notice; shared-source edits must never silently clear image payloads.
  Enforce PageImageLimits before native decoding: 10 MiB/image, 8192 pixels/side,
  16 million pixels/image, 64 million pixels/page and 100 images/page. Clipboard
  transfers are bounded at 16 MiB, separately from the 64 MiB archive/page budget.
  Preserve image-free legacy clipboard types and native text paste at the caret.
- Diagram snapshots must preserve native shapes, label/table text, connector
  anchors and styles through every edit, undo, duplicate, import and export.
  Enforce PageDiagramLimits before rendering or committing: 500 objects/page,
  20 rows/12 columns per table, 512 cells/page, 1,024 UTF-8 bytes/cell, 4,096
  UTF-8 bytes/label, 1 MiB aggregate diagram text and 100,000 patterned segments.
  Coordinates, widths and attachment references must validate. Deleting a target
  detaches surviving arrows at resolved endpoints; copying groups remaps copied
  object IDs and detaches references to omitted targets. Shapes move only their
  frames; connectors move their actual endpoints. Keep canonical colors and
  existing text/ink/image payloads intact. Clipboard v4 must retain bounded reads,
  accept v3/legacy payloads and advertise older types only without newer objects.
  iPad rejects diagram edits and diagram clipboard pastes explicitly.
- Preserve candidate-copy/validate/commit atomicity: rejected edits, imports, moves,
  or oversized duplicates must leave the previous library intact.
- Enforce the existing 64 MiB archive limit, 50,000-node limit, 128-level hierarchy
  limit, and 256-character title limit. The attachment picker caps files at 10 MiB;
  archive imports instead enforce the aggregate archive limit.
- Keep finite geometry checks and `InkGeometryLimits` shared across archives,
  clipboard input, model updates, and rendering. Patterned ink has an aggregate
  100,000-segment rendering budget; per-stroke checks alone are insufficient.
- A valid archive can put 49,000 sheets before a 127-folder ancestor chain.
  Folder-scoped sheet queries must build one adjacency index and membership set
  (`subtreeIDs`), not run a full-array ancestor search per sheet. The existing
  `descendants` helper also scans children repeatedly; it is not a safe substitute
  for this hot path. Preserve sorting, global search/Favorites/Trash behavior, and
  immediate membership changes after moves. Do not cache membership without
  covering every library mutation and import.
- Selected-file metadata is only a preflight check. `BoundedFileReader` must check
  the opened descriptor and read in bounded chunks, consuming at most the caller's
  limit plus one sentinel byte. Keep nonblocking open before rejecting nonregular
  files so a substituted FIFO cannot hang; keep regular symlink targets supported.
  Never restore `Data(contentsOf:)` for selected attachments or reopen the path
  after descriptor validation. Preserve security-scoped access and candidate
  validation before committing. The picker's 10 MiB and archive's 64 MiB limits
  are different: existing archived attachments above 10 MiB remain supported.

## Critical editor and cursor invariants

The earlier v0.2.1 callback tests passed while live hover still showed an I-beam.
Do not treat callback-level cursor assertions alone as proof of the displayed cursor.

- In ink mode, native body and movable-text editors must remain noneditable and
  nonselectable. Keep their visible content; never segregate writing and drawing.
- Selecting Text must restore native text editing and caret placement for ordinary
  pointers and connected styluses. Tablet detection must not override the chosen tool.
- Preserve `activePageCursor`, text-view cursor providers, clip/document cursor
  updates, tracking areas, and refresh after undo/redo or tool changes.
- Pen, Pencil, and Marker use proportional dot tips; Highlighter uses a slanted tip.
  Check width and zoom changes as well as switching from Text to ink.
- Plain tool letters are text while a text field/editor has focus. Keep the modified
  tool shortcuts working without stealing note, search, title, or equation input.
- The user's 3 November 2026 Select All request applies to every page tool.
  Command-A / Select All from the page editor must select body text, ink,
  positioned text boxes, equations, and images together, including from Text,
  Pen, or other tools. Preserve native Select All within unrelated focused
  search, title, equation-source, and other input fields; do not intercept it
  globally. Keep the image-bearing iPad read-only restriction intact.
- The user withdrew the new pressure experiment on 1 November 2026. Preserve
  the pre-experiment rendering and native PencilKit behavior; do not reintroduce
  the added 1×–2× pressure boost, completed-stroke width floor, portable native-width
  metadata, or pressure-sized cursor. Earlier tablet/PencilKit handling already
  consumed pressure; restoring it is not a guarantee of pressure-free native ink.
- Every writing-tool selection defaults to Fine. The latest requested nominal
  presets are Extra Fine/Fine/Medium/Broad/Extra Broad: Pen uses
  0.3/0.45/0.7/1/1.5 mm; Pencil and Straight Line use 0.3/0.45/0.7/1/1.3 mm;
  Brush (Marker) uses 0.5/0.7/1/1.5/2 mm. Highlighter retains its
  existing width choices. Extra Fine was explicitly requested again after the
  pressure experiment was withdrawn; it does not restore pressure enhancements.
  Convert mm using 72/25.4 points per mm and divide by the existing tool multiplier
  before storage; Mac rendering and native iPad configuration apply that multiplier.
  Do not multiply the requested millimetres twice or rewrite saved stroke widths.
  Preserve original tool color policies and explicitly supplied/custom widths.
- Every single-choice settings menu needs a visible checkmark and selected
  accessibility value: nib, paper, line style, template, template-line style,
  appearance, page colors, and scenery. Existing non-preset nib preferences must
  show as checked Custom, not silently snap to the closest named size. Verify
  visible menu state after changing a choice, including light/dark/system modes.
  macOS can strip `Label` images from a native menu: a checkmark SF Symbol is
  not proof of a checked item. Use native `Toggle` menu state with one-way
  selection semantics and verify the rendered menu; the current choice must
  not be cleared by selecting it again.
- Theme changes and chrome toggles must preserve the native editor instance,
  text/ink content, selection/caret, zoom, and input routing. Mac changes retain
  undo history. Existing iPad ink-theme reprojection recreates stroke IDs and
  deliberately clears native ink undo history to avoid targeting stale IDs;
  do not claim otherwise.
- Object-only undo/redo must retain exact body/text-box snapshots, including
  absent RTF in legacy plain text. A shared UndoManager notification does not
  prove that native text changed. Compare canonical attributed text before
  serializing; ignore only native fallback-font provenance in that comparison,
  preserving actual fonts, paragraph formatting and normal native text undo.
- Verify resized/collapsed panes using the actual visible editor viewport. A view
  existing in the hierarchy does not prove it is unobscured by another pane.
- Newer macOS column backing views can extend underneath the sidebar. Preserve
  the native nonoverlapping-column policy and older-layout measured inset fallback
  in `WorkspaceNavigationProbe`; backing-view width is not necessarily pane width.
  The sheet-number badge must pass pointer input through to the page.
- Use real Mac UI checks for cursor-sensitive changes. Mouse/simulator checks do
  not establish physical tablet pressure, tilt, Pencil hover, or palm rejection.

## Known regressions and testing traps

- **Heading fields received another role's native height.** Signed release run
  16 failed heading restoration after exact-source Native checks passed. Later
  passive repetitions captured a 10-point Tags field allocated 34 points instead
  of its native 13, and a 28-point Title allocated 13 instead of its native 34.
  Constraining only outer SwiftUI frames kept the viewport stable while a native
  field still overflowed. Check actual native field frames as well as viewport
  geometry, including passive hide/show and sheet switching. Preserve original
  failure observations, drift thresholds and sampling requirements. Owned Mac
  heading controls must retain field-local Select All, direct UndoManager
  undo/redo synchronization, raw editing spaces, marked text and read-only
  behavior. The internal framework mechanism is not established by these
  observations. Consult the versioned validation record for the candidate result.

- **A fixed settling delay expired during a native pane animation.** Release
  run 17 checked the restored width while exit generation 12 still had one native
  completion pending; current pane references matched and title/tag heights were
  correct. An earlier transition took 0.470 seconds after its deferred start,
  exceeding the general fixture's 0.4-second assumption. Final geometry must be
  asserted at callback quiescence, bounded to five seconds, without waiting for
  the desired width as the readiness predicate. Keep the first completed-state
  observation, original nominal-window evidence when still pending, every early
  motion sample and actual sample gaps. Do not force layout, relax geometry or
  turn a wrong completed state into a pass by waiting for later recovery.

- **Hosted load exhausted a sheet-switch sampling window.** Release run 12
  (unpublished build 2014) observed one sample after a slow run-loop turn, with
  zero measured drift, stable probe identity and no collapse events. Keep the
  diagnostic's minimum 12 post-turn observations, nominal 0.6-second window and
  5-second timeout. Do not reuse an expired deadline to count same-turn samples,
  discard early drift/KVO evidence, force layout, or relax geometry thresholds.
  Preserve the diagnostic-only first-turn stall regression and log sample gaps;
  late observations do not establish continuity across an unsampled gap.

- **Sidebar layout stayed stale until a page click (reported after v1.0.2).**
  With the sheets pane hidden, the native sidebar could close while leaving a
  sidebar-width blank gutter, or open over the heading/tools/page. The detail
  hosting view extended underneath navigation, so the background probe's own
  bounds/layout callback did not reliably change. Observe native split resize
  events and sidebar collapse state; coalesce a geometry-only inset refresh.
  Do not rely on another SwiftUI update, a page click, or a delayed fixed timer.
  Keep geometry observation separate from pane sizing/collapse policy, and remove
  observers when the controller changes or the probe is detached.
- **Forced layout masked that sidebar bug.** The original workspace fixture
  repeatedly called `layoutSubtreeIfNeeded()` while waiting, so it repaired the
  UI in a way an idle user would not. The regression must invoke the real native
  `toggleSidebar` action and wait only for normal run-loop/animation processing.
  Assert viewport alignment after both hide and show, with sheets visible and
  hidden, in Text and Pen modes. No forced layout, redraw, unrelated preference
  change, or page click may occur between that action and its assertions.
- **Native backing width is not visible pane width.** An underlay can include
  the sidebar. Preserve the measured visible width across collapse/restore;
  inspect actual unobscured page edges rather than checking view existence.
- **Cursor callbacks alone gave a false pass in v0.2.1.** Retain the safeguards
  above and distinguish actual displayed-cursor captures from native cursor
  ownership assertions. A native hover probe must verify that its app is actually
  the top window at the pointer, not merely marked key/active. `NSView.hitTest`
  expects superview coordinates, even for flipped hosting views. An obscuring
  chat window can make system-cursor captures misleading. Do not claim physical
  stylus testing from synthetic input.
- **Sheet changes reopened panes and shifted the workspace.** A SwiftUI `Group`
  forwarded the navigation-probe background into `SheetDetail.id(sheet.id)`.
  Changing sheets therefore dismantled the probe and restored initially open
  native panes. Keep the probe on the stable outer `ZStack`; preserve a separate
  sheet-ID boundary for the editor. Removing that ID without resetting its
  coordinator/undo manager can apply one sheet's undo history to another sheet.
  Clearing selection must not override independently hidden pane preferences.
- **Correct final geometry did not prove smooth motion.** Calling
  `layoutSubtreeIfNeeded()` and repositioning a divider during native expansion
  forced the workspace to its destination early and caused a backward bounce.
  Let AppKit own pane animation; restore a saved width only after completion and
  only if it differs. Skip intermediate width capture, avoid repeated policy
  assignments, guard interrupted completions, and respect Reduce Motion.
  On macOS 26+, disable underlay layout for both middle and detail items together,
  preserving/restoring their native policies. Detail-only opt-out was insufficient.
  While native columns animate, a target navigation frame can precede the moving
  detail frame; do not mistake that for overlap and add SwiftUI padding, which
  cancels the rendered movement. Use one owner for column geometry.
  Keep the measured inset fallback for older or overlapping layouts.
  Regression tests must sample sheet-switch geometry and native collapse events
  throughout the transition, exercise rapid reversals and detachment, and use
  presentation-layer samples for animation rather than mistaking target model
  frames for rendered frames. Record when presentation samples are unavailable.
- **Interrupted pane animation can overwrite restored state.** A plain
  `isCollapsed` assignment, a zero-duration replacement, or temporarily disabling
  the default collapse animation alone does not reliably cancel a native group
  that has been queued but not started. Isolated probes passed while the full
  optimized app still failed. Keep teardown restoration alive only through the
  outstanding native completions, with controller ownership and reentrancy guards;
  an old owner must never override a replacement owner's latest intent. Verify
  same-main-turn detach, restoration throughout the pending transaction, original
  pane policies/widths, and replacement ownership in the full release harness.
  Do not substitute a fixed delay or weaken the regression to final geometry alone.
  Keep pre-full-page state through a rapid exit/re-entry, then discard it once
  exit completes so a later sheets transition cannot restore a stale sidebar.

## Themes, rendering, and footprint

Keep ruled text aligned with paper guides; preserve solid/dashed/dotted lines,
templates, selection, equations, and combined exports when modifying rendering.
Page color is a global preference. Its default Match scenery and appearance
choice resolves paper and guide colors from the selected scenery in light/dark
mode; Ruby Hills dark paper is maroon-black. Explicit paper choices are fixed
independently of scenery and appearance: Vintage White (legacy `vintage`),
Vintage Black, Pitch Black, Pitch White, and Pastel Peach/Rose/Lavender/Mint/Sky.
Pitch papers use neutral grey guides. Use `PageTheme.isDark` for native text
appearance, cursor contrast and ink rendering; equality with `.dark` covers only
Classic. Preserve legacy `forest` → Nature resolution for paper too.
Light/dark or vintage changes must not rewrite canonical stored text/ink colors.
The native ink picker stores opaque canonical sRGB hex values; swatches resolve
only their displayed color. Theme changes must preserve custom colors and all
previous strokes, and must not reset tool widths or add pressure behavior.

The twelve supplied Coast/Alpine/Arctic/Open Skyscape/Ruby Hills/Nature PNGs live in
`Sources/NotesApp/Resources/WorkspaceThemes`. Preserve their light/dark mapping,
Mac relocated-resource-bundle lookup, iPad main-bundle lookup, and bounded native
image caching. Forest is no longer selectable or bundled; resolve its legacy
preference to Nature consistently across scenery, accents, and checked menus.
Scenery must not intercept input or replace the editor.
Avoid web runtimes, cloud SDKs, unnecessary image duplication, and unbounded caches.
Measure app/DMG file bytes separately from RAM; an artifact size is not a memory benchmark.

## Storage, backups, and safe QA

Production data is `~/Library/Application Support/iNotes/Library.json`, with
`Library.previous.json` for the previous save. Preserve damaged originals and
external-change detection; failed saves must not permit an updater restart.
Use temporary libraries (`INOTES_DATA_DIR` or explicit test directories) and an
isolated QA app identity for manual work. Never use real notes for destructive tests.
Use a dedicated simulator; do not erase or alter unrelated simulators.

The user confirmed combined manual QA of the numbering and Select All fixes
on 3 November 2026. Exact-source Native checks passed, and public v1.0.4 build
2016 was independently verified after publication. The release workflow failed
its cached-feed readback after publishing; do not describe that workflow as
passed. See `docs/TESTING.md` for actual checks and remaining limits. The
isolated QA app uses a separate bundle identity, QA build 1, temporary notes,
and a disconnected updater. Do not use computer control or interactive UI automation.

Google Drive and iCloud Drive integration writes versioned `.inotes` folder backups.
Providers upload those files; iNotes does not provide CloudKit or bidirectional
conflict merging. A successful folder write does not prove cloud delivery.
Keep destinations, failures, retries, and connection state independent. Imported
backups add separate copies. Local note/attachment data is not app-level encrypted.

Managed backups live in `iNotes Backups/Automatic-<local-library owner UUID>`.
Automatic writes and Back up now share retention (latest 5, up to 7 UTC daily and
4 UTC weekly copies, 500 MiB); independent exports are permanent. Never prune
another owner's files or legacy root archives automatically. Verify a current
archive by bounded read-back before pruning and protect the newest two valid
copies. Keep cleanup warnings separate from backup write failures; safety skips
can leave history above budget. Legacy cleanup requires a reviewed selection,
fresh verified backup, unchanged directory/file identities and content, and
newest-two protection. Preserve bounded, descriptor-relative no-follow operations
and batch large reviews; tests must use temporary folders only.

## Security record and review rules

`docs/TESTING.md` records a v1.0.0 Codex Security standard scan of 78 tracked files
at `965306f`. It reported one Low patterned-ink rendering-exhaustion issue; the
release added the shared aggregate budget, a defensive renderer check, and regressions.
That was static review plus regression testing, not a dependency CVE scan or a
standing assurance that current code has no vulnerabilities.
The 1 November 2026 standard scan at `00092ba` reviewed 78 tracked text/source/
configuration files and inventoried 10 PNGs. It reported two Low resource-
exhaustion issues: repeated ancestry scans on imported hierarchies and an
attachment metadata-to-unbounded-read race. The follow-up adds indexed subtree
membership and a shared descriptor-checked bounded reader, with adversarial and
compatibility regressions. See the dated security-fix section of `docs/TESTING.md`
for actual commands/results; do not apply that result to a later untested patch.
These checks do not establish dependency-CVE coverage or absence of all defects.
When a security scan is requested, use the named security workflow and report its
actual scope, revision, findings, fixes, and verification limits. Never invent a pass.
Treat imported archives, clipboard payloads, filenames, geometry, and equation source
as untrusted. Keep bounded parsing/rendering and atomic rejection at those boundaries.

## Validation workflow

Run from the repository root after relevant source changes:

```sh
bash scripts/test.sh
bash scripts/build-macos.sh
bash scripts/verify-macos.sh
dist/iNotes.app/Contents/MacOS/iNotes --smoke-test --editor-test
bash scripts/generate-appcast.sh
bash scripts/test-update-signatures.sh
```

The last two commands require the existing private signing identity and prepare
local artifacts only. Native editor checks require a graphical Mac session.
Coordinate source freezes with other contributors: SwiftPM tests also compile the app.
Register new core test methods in `StandaloneRunner.swift` as well as XCTest.
Run iPad compilation for shared-source changes; see `docs/BUILD.md` for the command.
For opt-in iPad DEBUG checks, launch a dedicated simulator with
`SIMCTL_CHILD_INOTES_IOS_EDITOR_DIAGNOSTICS=1` and read its
`Library/Caches/iNotesEditorDiagnostics.json` result.

As a historical reference, local v1.0.1 recorded 260 editor, 74 workspace,
31 equation, 12 ruled-text, 8 shortcut, and 164 iPad native checks. Hosted SDKs can
produce different counts. Do not copy these numbers into a new release's result;
record that build's actual output, commit, OS/SDK, artifact checksum, and limitations
in `docs/TESTING.md`. Repeat relevant live/manual checks listed there.

## Git and releases

Review the working tree before edits; preserve unrelated work and keep changes
scoped. Do not commit generated `dist/`, `.build/`, test libraries, or `.private/`.
Keep release notes, version defaults, and iPad project metadata consistent.
Source pushes run `Native checks`; a `vX.Y.Z` tag runs the publishing workflow.
Do not push a release tag merely to test packaging. Confirm publishing is authorized
and checks are complete; verify the separately built public assets after release.
Sparkle compares build numbers: choose a value greater than the latest published
`CFBundleVersion`; hosted release builds now use `2002 + GITHUB_RUN_NUMBER`.
Run 10 shipped build 2010; the manual same-version security rebuild reserved 2011,
and v1.0.4 run 11 published 2012. Backup QA used 2013; dispatched run 12 built
2014 but failed verification before publishing. Run 13 published 2015, and run 14
published 2016. Run 15 published v1.1.0/build 2017 from `7946a931`; its exact-source
Native checks and separately downloaded public assets passed on 4 November 2026.
Run 16 built v1.2.0/build 2018 from `ca051953`, then failed the heading-restoration
workspace assertion before publication; preserve that tag and build reservation.
Run 17 built v1.2.1/build 2019 from `adf533e4`, then failed the pane-width
assertion during an unfinished native exit before publication. Preserve that
tag and reservation too. Run 18 published v1.2.2/build 2020 from `aa392994`;
exact-source Native checks,
signed release checks and independently downloaded public assets passed.
The verified public release remains v1.2.2/build 2020. Current development
defaults target unpublished v1.3.0 / prospective build 2021.
Initial v1.2.0 user QA and publication authorization were recorded on
5 November 2026; they do not establish
later-source or public-build results. The v1.1.0 local QA identities use separate
QA builds 1 and 2 (final Pen correction). The next new signed-release run (19)
must produce 2021; recheck both feed and counter immediately before publication.
A workflow rerun does not
advance `GITHUB_RUN_NUMBER`. Never reuse its build number for an updated binary.
The release workflow supports an explicit `workflow_dispatch` for the current
stable version; wait for Native checks on its exact source commit first.
GitHub may briefly serve a cached old feed after asset replacement. Preserve the
bounded exact-byte readback wait before final signature checks; a stale read must
not cause a signed feed to be edited or an installer build number to be reused.
For a same-version rebuild, preserve the original tag and old installer, upload a
distinct build-numbered DMG/checksum first, verify their public bytes, then replace
the signed appcast last. Record the new source commit in the release notes;
the original version tag still identifies the original build. Recheck the public
feed and release counter before publishing and reserve any manual build slots.
The old 1000-based counter would have produced build 1010 after local candidates
1010–1012, preventing Sparkle from offering that release to those copies. Always
check both the public feed and previously shared local builds before publication.

Both feed and DMG use the existing Ed25519 identity. Never print, commit, attach,
or place the seed in command arguments/logs. `.private/updates/ed25519.key` is
private; `Resources/UpdatePublicEDKey.txt` is public. CI uses `SPARKLE_PRIVATE_KEY`.
Do not regenerate the identity casually: installed apps trust the existing key.
Never edit an already signed appcast; regenerate and verify final artifacts.
Current Mac distribution is ad hoc signed and not Apple notarized. Sparkle
signatures establish update authenticity, not Developer ID signing, notarization,
or Apple's malware assessment. iPad distribution uses Apple's signing/update system.
