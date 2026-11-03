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
- `Sources/NotesApp/NotesStore.swift`: observable library state, mutations,
  autosave, recovery, and independent cloud-folder backup scheduling.
- `ContentView.swift`, `SheetDetail.swift`, `WorkspaceAppearance.swift`: navigation,
  sheet UI, tools, themes, and workspace presentation. Keep layout changes here
  separate from drawing/input behavior unless the task requires both.
- `Editors/UnifiedPageEditor.swift`: shared Mac page using AppKit text and ink layers.
  `RichTextEditor.swift`, `MacPageObjects.swift`, and `MacPageSelection.swift`
  participate in native text, object, selection, undo, and cursor behavior.
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
- Archive format 3 reads formats 1 and 2. Image-free new libraries default to format 2;
  adding positioned text/equations promotes format 1 to 2, and adding page images
  promotes to 3 without later downgrading. Add decoder defaults and legacy fixtures.
- Page images are canonical PNG objects behind text and ink. Preserve them in every
  page snapshot, undo operation, duplication/import, mixed clipboard payload and
  PDF/PNG export. Image-bearing iPad sheets are currently read-only with an explicit
  Mac-only notice; shared-source edits must never silently clear image payloads.
  Enforce PageImageLimits before native decoding: 10 MiB/image, 8192 pixels/side,
  16 million pixels/image, 64 million pixels/page and 100 images/page. Clipboard
  transfers are bounded at 16 MiB, separately from the 64 MiB archive/page budget.
  Preserve image-free legacy clipboard types and native text paste at the caret.
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
  presets are Extra Fine/Fine/Medium/Broad: Pen, Pencil, and Straight line use
  0.3/0.45/0.7/1 mm; Brush (Marker) uses 0.5/0.7/1/1.5 mm. Highlighter retains its
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
- Verify resized/collapsed panes using the actual visible editor viewport. A view
  existing in the hierarchy does not prove it is unobscured by another pane.
- Newer macOS column backing views can extend underneath the sidebar. Preserve
  the native nonoverlapping-column policy and older-layout measured inset fallback
  in `WorkspaceNavigationProbe`; backing-view width is not necessarily pane width.
  The sheet-number badge must pass pointer input through to the page.
- Use real Mac UI checks for cursor-sensitive changes. Mouse/simulator checks do
  not establish physical tablet pressure, tilt, Pencil hover, or palm rejection.

## Known regressions and testing traps

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
Page color is a global preference, distinct from scenic workspace appearance.
Light/dark or vintage changes must not rewrite canonical stored text/ink colors.

The six supplied Coast/Forest/Alpine PNGs live in
`Sources/NotesApp/Resources/WorkspaceThemes`. Preserve their light/dark mapping,
Mac relocated-resource-bundle lookup, iPad main-bundle lookup, and bounded native
image caching. Scenery must not intercept input or replace the editor.
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
and authorized publication on 3 November 2026. The isolated QA app uses a new
bundle identity, QA build 1, temporary notes, and a disconnected updater. Do not
use computer control or interactive UI automation. Public v1.0.4 build 2016
remains a candidate until exact-source hosted checks and release verification
complete; record actual checks and any deferred gates in `docs/TESTING.md`.

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
2014 but failed verification before publishing. Run 13 published 2015. Production
candidate defaults now reserve 2016 for the numbering and Select All fixes; its separate QA
identity uses build 1. The next new run (14) must produce 2016. A workflow rerun does not
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
