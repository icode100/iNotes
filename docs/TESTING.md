# Validation

## 1.3.0 shapes, connectors and tables candidate — 6 November 2026

This candidate is local and unpublished. The previous 1.2.2 results below do not
establish validation of this new patch. The worktree adds archive-format-4 vector
objects, bounded tables/cell text, attached connectors, native Mac editing and a
read-only iPad preview. No dependencies or production notes are used.

The frozen portable model passed `TMPDIR=/private/tmp bash scripts/test.sh`:
**133 standalone tests, zero failures, 3.93 seconds**, including seven new diagram
cases and all existing core tests. Evidence is
`/private/tmp/inotes-v1.3-core-tests.log`.

Local ARM64 release compilation uses Swift **6.4.2**, macOS SDK **27.2** and
macOS **27.2 (26B123)** through Command Line Tools. Native diagram fixtures cover
gesture preview/commit, attached-arrow movement, resizing/reconnection, table
cell Save/rejection, exact mixed-content undo/redo, bounded clipboard remapping,
save/reopen, canonical theme changes, searchable PDF/PNG, and native body/text-box
typing/font/paragraph undo. The toolbar's actual Bold action is exercised through
its app-local active-editor fallback; this is not a physical keyboard/IME result.

An intermediate run found that a diagram-only undo serialized unchanged body
and text-box text, materializing RTF that was absent in the original snapshot.
The shared native text observer now checks canonical attributed content before
serializing. Actual Unicode attribute-run captures identified `NSOriginalFont`
provenance on fallback glyphs; only that metadata is omitted from comparison,
while real fonts and paragraph attributes remain significant. Persistence itself
is unchanged. Exact nil-RTF and already-formatted snapshots, plus real native
typing/font/paragraph undo/redo, are retained as regressions. Gesture coordinate
checks allow only 0.000001 unzoomed page point for native event-transform rounding;
IDs, content snapshots, text and attachment semantics remain exact.

The nested-fixture full runs in `inotes-v1.3-native-tests-9.log` and `-10.log`
each passed **104 diagram / 964 total editor / 31 equation / 12 ruled-text /
9 shortcut checks**, but failed the narrow-window sheets-hide completion check.
Generation 17 remained pending for the full five seconds while frequent passive
samples retained the old 236.5-point viewport. All 100 heading cycles retained
correct native allocations. This was a genuine failed fixture transition,
distinct from the older fixed-0.4-second assumption; the timeout and geometry
assertions were not relaxed. The failed executable's SHA-256 was
`37955be84bfcce6d8f654c6df1cfa7592a118378a5c35aa68f8bb8b19f64453c`.

A fresh-process `--smoke-test --workspace-test` invocation passed **2,000 workspace
checks**, store/updater checks (16 configurations), **62 numbering/title/store
checks**, the 49,127-node hierarchy case and independent backup integration.
The same narrow collapse completed in **0.311608 seconds**. Evidence is
`/private/tmp/inotes-v1.3-workspace-only.log`. This scoped pass does not replace
the failed full-suite result. The optional `--diagram-test` and `--workspace-test`
drivers isolate fixtures; the regular `--editor-test` pipeline remains the full
release check.

Running standalone Diagram → Workspace also failed the first sheets-hide
transition (generation 2), so moving the fixture outside its parent alone was
not sufficient. The final change scopes the complete diagram fixture in an
autorelease pool, letting Swift locals and deferred window closure finish before
draining Cocoa temporaries. Passive weak-reference logging confirms the fixture
window, hosting view, native page and selection controller are released after
that boundary, with no modal sheet and balanced undo grouping. No native layout,
animation flush, forced drawing, geometry tolerance or pane-policy change was
introduced. These observations do not establish an internal AppKit mechanism.

The final full `--smoke-test --editor-test` run exited **0** and passed:

- **964 native editor checks**, including **104 diagram checks**.
- **2,000 workspace / 31 equation / 12 ruled-text / 9 shortcut checks**.
- Store/updater integration (16 configurations), **62 numbering/title/store
  checks**, the **49,127-node** hierarchy case and independent backup integration.
- All **100** passive heading cycles and the strict callback-completion,
  visible-viewport, rapid-reversal and sheet-switch checks.

Evidence: `/private/tmp/inotes-v1.3-native-tests-11.log` and optimized compilation
`/private/tmp/inotes-v1.3-build-13.log`. Earlier failed and scoped logs above remain
distinct evidence; the pass does not erase them. The baseline public 1.2.2 copy
was prepared and verified in temporary storage but was not run.

The isolated app is `dist/iNotes-QA-1.3.0.app`, identity
`io.inotes.qa.v130.20261106`, version **1.3.0 / QA build 1**, with a disconnected
updater and demo/practice sheets at `/private/tmp/inotes-v1.3-qa-rg6yxp_r`.
Strict deep ad hoc signature and plist/project syntax checks passed. Source and
package-file manifest SHA-256:
`cc38571de82a93a844ddd2a4c7777cc7d41ece246a42cb6c999f9133ea1dfde2`.
Executable **7,312,864 bytes**, SHA-256
`038b585f11baa8698104ebc0fa1056a074026e2abd508fa677d4b67b87529eb4`.
The QA template contains **47,338,087 regular-file bytes** across **127 files**;
these are QA artifact sizes, not a distribution-size or RAM result. Ignored
`dist/qa-v1.3-source-manifest.json` records individual source hashes. Manual user
QA and publication approval for this new feature remain pending.

Full Xcode/iPad SDK and installer icon compilation are unavailable on this
Command Line Tools host. `bash scripts/build-macos.sh` stopped at the explicit
missing-`actool` preflight (`inotes-v1.3-packaging-preflight.log`); no candidate
DMG, mounted-installer or Ed25519 artifact result is claimed. iPad source includes
read-only diagram/paste/viewport fixtures but has not compiled or run here.
Hosted checks and user QA remain required before publishing. No new physical
stylus, iPad, actual IME, displayed-cursor capture or cloud-delivery result is
implied. All new checks use temporary notes and app-local input, without external
computer control.

## v1.2.2 / build 2020 published and independently verified — 5 November 2026

Published [v1.2.2](https://github.com/icode100/iNotes/releases/tag/v1.2.2) uses
source `aa392994ed290e38819a74e0a21f5dad520642a3`, tag `v1.2.2`, version
**1.2.2** and build **2020**. Both exact-source hosted Native runs passed:
[branch 42041114016](https://github.com/icode100/iNotes/actions/runs/42041114016)
and [main 42046399201](https://github.com/icode100/iNotes/actions/runs/42046399201),
including mounted-DMG verification and iPad compilation.

[Signed release run 18 / 42046511381](https://github.com/icode100/iNotes/actions/runs/42046511381)
completed **successfully** on macOS **26.6.2**, image **20261026.0455.2**.
It repeated **126 XCTest tests, zero failures, 13.675 seconds** (13.707 wall),
ARM64 packaging, **852 editor / 2,000 workspace / 31 equation / 12 ruled-text /
8 shortcut / 62 numbering-title-store checks**, the existing updater/backup
integration and mounted-bundle/resource/icon/persistence verification.
All 100 heading cycles retained correct native allocations. Fifty-five completion
waits included **17** pending observations beyond 0.4 seconds; the maximum
completion time was **0.611975 seconds**. All six sheet switches retained zero
observed frame/field-height drift; the first injected-stall gap was **0.913775
seconds**. Sampling gaps do not establish unsampled continuity. Feed/archive
Ed25519 verification, all five tamper probes, asset publication and signing-seed
cleanup passed. The release compiler/SDK was not separately printed; iPad
compilation belongs to the Native runs above.

Independent verification downloaded the three assets from public release
**435327898**, published at **14:45:40 UTC**. API SHA-256 digests and lengths,
the checksum file, and versioned/latest feed byte equality passed on the first
readback attempt. The signed feed advertises **1.2.2/build 2020**, the exact
versioned HTTPS enclosure and its measured installer length.

- Public DMG: **34,632,864 bytes**, SHA-256
  `8e54abc82f09d00c9cff36e76ffbba4ee32e71a39b275538b646839b9eefc645`.
- Public feed: **1,268 bytes**, SHA-256
  `968b72d9c7afcc300f160f9f43bd3784510b612c187f6eab5ddf10632de8bed0`.
- Mounted app: **41,809,499 regular-file bytes** across 106 files; executable
  **6,842,480 bytes**, SHA-256
  `091762ecb137731322a4411a0d28bed5245868e55bad512a9878fc8faeaac7e1`.
  These are artifact file sizes, not RAM measurements.

The existing signature script independently passed all **five** public
feed/archive checks against the committed Ed25519 key. `verify-macos.sh` mounted
the downloaded DMG read-only and passed checksum, strict ad hoc signatures,
ARM64, macOS 14 deployment target, Applications link, all twelve scenery hashes,
math resources, native light/dark icon stacks and isolated persistence/backup
smoke checks. Additional read-only inspection confirmed production identity
`io.inotes.app`, version/build, no QA/environment overrides, the unchanged update
public key and required production updater settings. The public tag resolves to
the exact validated source. Prior v1.1.0/v1.0.4 asset identities/digests and tags,
and failed v1.2.0/v1.2.1 tags, remain unchanged.

Public evidence is in ignored `dist/public-v1.2.2/verification.json` and temporary
logs `inotes-v1.2.2-public-download.log`, `inotes-v1.2.2-public-signatures.log`,
`inotes-v1.2.2-public-bundle-verification.log`, `inotes-v1.2.2-public-inspection.log`
and `inotes-v1.2.2-prior-preservation.log` under `/private/tmp`.
The release evidence is
`/private/tmp/inotes-v1.2.2-signed-release-evidence-summary.json`.
Initial user manual QA applies to 1.2.0; these results do not add a physical
stylus/Pencil/IME, displayed-cursor capture, older-OS, cloud-delivery or actual
updater-installation result. No production notes or external computer control
were used. Current distribution remains ad hoc signed and not Apple notarized.
Failed unpublished builds 2018/2019 remain reserved; the next fresh release run
19 must use build 2021 or higher after a live feed/counter check.

## v1.2.2 exact-source local and hosted validation — 5 November 2026

Source `aa392994ed290e38819a74e0a21f5dad520642a3` passed the final isolated local
native harness and [hosted Native checks 42041114016](https://github.com/icode100/iNotes/actions/runs/42041114016).

The local optimized ARM64 build ran on macOS **27.2**, Swift **6.4.2**, with
Command Line Tools. Its native executable exited **0**. Hosted checks used macOS
**26.6.2**, image `macos-26-arm64` `20261026.0455.2`, Swift **6.3.3**, Xcode
**26.6**, and iPhoneSimulator SDK **26.5**.

| Check | Local | Hosted |
| --- | --- | --- |
| Native editor | 853 passed | 852 passed |
| Workspace | 2,000 passed | 2,000 passed |
| Equations / ruled text / shortcuts | 31 / 12 / 8 passed | 31 / 12 / 8 passed |
| Numbering/title/store | 62 passed | 62 passed |
| Core XCTest | Not rerun in this final local native invocation | 126 tests, zero failures, 15.311 seconds (15.361 wall) |

Hosted ARM64 packaging, mounted-DMG verification and iPad simulator compilation
passed. The local CLT native harness is a separate artifact and does not establish
full installer packaging. Both runs passed **100 heading hide/restore cycles**;
actual owned native controls retained **34-point title** and **13-point Tags**
heights. Native input checks cover raw multiword/Unicode drafts, local Select All,
direct undo/redo synchronization, caret preservation/clamping, synthetic marked
text, rejection/truncation, tag commits, and read-only transitions.

The completion-wait correction leaves production pane policy unchanged. Readiness
uses accepted intent, native completion/ownership and queued work, with an
absolute **five-second** timeout; it does not wait for desired geometry. The first
completed geometry result is retained, so later recovery cannot replace a failure.
Deterministic virtual-clock checks enforce that rule and reject stalled or
permanently pending callbacks.

Hosted evidence contains **55 completion waits**: **16** were still pending beyond
the former 0.4-second window; the longest completed at **0.649535 seconds**. For
“exit full page with tools hidden”, the preserved **0.429329-second** observation
still had generation 12 pending with last completion 11. The first idle observation
at **0.451123 seconds** had pending zero, completion 12 and the correct **582-point**
viewport width. Geometry thresholds were unchanged.

Each run passed all **six sheet switches**, retaining the strict **0.6-second
minimum, 12 post-turn observations and five-second deadline**, zero observed
frame/title/tag drift, stable probe identity and no collapse events. The largest
logged sample gap was **0.740945 seconds locally** and **1.102507 seconds hosted**,
including the injected stall. These observations do not establish continuity
through unsampled intervals.

Healthy hosted logs print motion summaries and collapse observations, but detailed
actual action-delivery traces remain unprinted on success; nominal rapid-action
offsets alone do not establish delivery cadence. These are isolated in-process
fixtures and simulator compilation, not physical stylus/Pencil, actual IME,
displayed-hover, older-OS or cloud-delivery validation.

## v1.2.1 exact-source hosted Native checks — 5 November 2026

Source [`adf533e4`](https://github.com/icode100/iNotes/commit/adf533e4f4ad190422111e531c8c038e72bbfbb6)
passed [branch Native checks 42035913994](https://github.com/icode100/iNotes/actions/runs/42035913994)
and [duplicate main Native checks 42037619009](https://github.com/icode100/iNotes/actions/runs/42037619009).
Both completed all workflow steps, including mounted-DMG verification and iPad
simulator compilation. They are separate from the failed signed-release build.

The branch run used macOS **26.6.2**, image **20261026.0455.2**, Swift **6.3.3**.
It recorded **126 XCTest tests, zero failures, 10.861 seconds** (10.893 wall),
**852 editor, 1,940 workspace, 31 equation, 12 ruled-text, 8 shortcut and 62
numbering/title/store checks**, plus the existing updater/backup integrations.
All **100** passive heading cycles kept actual native title/tag heights at
**34/13 points**. All six sheet switches retained zero measured frame, title-height
and tag-height drift, stable probe identity and no collapse events, with **13
total / 12 post-turn observations** each. The injected **0.785981-second** stall
produced a **1.088668-second** sampling gap; later samples do not establish
continuity across that gap.

Evidence: `/private/tmp/inotes-v1.2-nativecontrol-evidence-summary.json` and
`/private/tmp/inotes-v1.2-nativecontrol-42035913994-logs.zip`.
These passes establish the recorded builds' results; they do not establish a
separately rebuilt public release, physical input devices or every older OS.

## v1.2.1 / build 2019 signed release failed before publication — 5 November 2026

[Signed release run 17 / 42037656071](https://github.com/icode100/iNotes/actions/runs/42037656071)
used exact source `adf533e4f4ad190422111e531c8c038e72bbfbb6`, version **1.2.1**,
build **2019**, macOS **26.6.2 (25G83)** and image **20261026.0455.2**.
It passed **126 XCTest tests, zero failures, 10.459 seconds** (10.493 wall),
ARM64 app/DMG creation and packaging smoke checks, including 62 numbering/store
and 16 updater configurations plus independent backup integration.

The native step passed **852 editor, 31 equation, 12 ruled-text and 8 shortcut
checks**, and all **100** heading repetitions retained correct title/tag native
heights. It then failed “leaving full page restores the previous navigation
layout”: viewport width was **813** versus baseline **582** points. The captured
probe had `transitionInProgress=true`, generation **12**, one pending native
completion and queued synchronization/geometry work. Its last completion was
entry generation 11. Current item references matched; both panes' model collapse
flags were already false, while their frames were still moving. The snapshot
therefore did not establish completed final geometry.

The trace also showed an earlier native completion taking **0.469956 seconds**
after its deferred start, exceeding the general fixed **0.4-second** settling
assumption. Generation 9 began about **10 ms** before generation 8 completed.
The old failure snapshot lacked a monotonic capture time, so generation 12's
precise age cannot be recovered from buffered output timestamps. These facts
justify completion-based readiness, without establishing a production pane fix
or permitting geometry thresholds or early motion evidence to be discarded.

`verify-macos.sh` and the Ed25519 scripts were **not reached** in that step;
publication was **skipped** and seed cleanup **passed**. There are no public
1.2.1 assets to verify. Preserve its annotated tag object
`c6006556a0b38f1f3a9609119c99604ad953e47e`, peeled source `adf533e4` and build
2019 reservation. Evidence is
`/private/tmp/inotes-v1.2.1-signed-release-evidence-summary.json` and
`/private/tmp/inotes-v1.2.1-signed-release-verification.log`.

## v1.2.1 owned heading inputs — local verification, 5 November 2026

Source [`adf533e4`](https://github.com/icode100/iNotes/commit/adf533e4f4ad190422111e531c8c038e72bbfbb6)
replaces the Mac title/tag inputs with an owned native field and container for
each fixed role. Font assignment precedes native measurement, and the actual
child's height follows its own font metrics. The iPad input path remains SwiftUI.
The earlier outer-frame-only attempt is not treated as a successful fix.
The archive format, stored page content, pressure behavior and pane policy did
not change in this correction.

The exact local source/manifests SHA-256 is
`f34b07cd0d2e12615b2f826c87a1b3d7afcbd29518026f172781a8f9632a786b`.
On Apple silicon, macOS **27.2 (26B123)**, Swift **6.4.2**
(`swiftlang-6.4.2.1.9 clang-2100.4.1.1`) with Command Line Tools:

- **126 standalone core tests, zero failures, 3.75 seconds**.
- The frozen ARM64 native build and complete isolated `--smoke-test --editor-test`
  run passed: **853 editor, 1,940 workspace, 31 equation, 12 ruled-text,
  8 shortcut, 62 numbering/title/store and 16 updater-configuration checks**,
  plus the existing store and independent-backup integrations.
- All **100** repeated passive heading cycles completed with actual native
  title/tag allocations checked alongside viewport geometry. Sheet-switch
  samples recorded zero measured frame, title-height or tag-height drift,
  stable probe identity and no native collapse events. The original sampling
  counts, thresholds and deadlines were retained. The injected first-turn stall
  produced a **0.741288208 s** maximum sample gap; later observations do not
  establish continuity through that unsampled interval.
- Actual component input checks passed native typing and trailing-space/Unicode
  title normalization, local Select All/tool-letter protection, direct native
  UndoManager undo/redo synchronization, external/model/theme refresh with
  retained focus/caret, rejected rename rollback, the 256-character Unicode
  bound, clearing, Tags Return/blur/disappearance commits, read-only/reinserted
  heights and save/reopen with unchanged page text, ink and objects.
- The native marked-text fixture passed composition preservation during model
  and theme updates and publication after commit. This exercises the native
  input-client path synthetically; it is not physical input-method validation.

The initial unrelated-input fixture incorrectly required all three controls to
share one UndoManager because they shared an NSTextView field editor. Measured
values showed the same editor with distinct nonnil per-control managers. The
fixture now enables native undo for its plain unrelated field, logs the actual
relationship, exercises each real manager directly and verifies that old heading
manager notifications cannot publish another control's text. The real unrelated
undo/model-isolation assertions remain; the runtime does not substitute a shared
manager merely to satisfy the fixture.

The original full-page exit assertion passed in this local run. Its earlier
failure on unchanged v1.1 source is retained as baseline evidence; neither that
baseline failure nor this local pass establishes its cause or a production pane
fix. No pane behavior was changed on that hypothesis.

Diagnostic executable: **6,611,968 bytes**, SHA-256
`934328a14da79fd3d4f84ac5f2885c6549106102ab6c7e7aa85d68b201043be6`.
These are local diagnostic artifact bytes, not release installer or RAM
measurements. Evidence is
`/private/tmp/inotes-v1.2.1-native-heading-local-evidence.json`, with build/native
logs `inotes-v1.2.1-native-heading-build-3.log` and
`inotes-v1.2.1-native-heading-tests-3.log`, and core log
`inotes-v1.2.1-core-tests.log` in the same temporary directory.

This CLT result does not establish full-Xcode production packaging, adaptive icon
verification, iPad compilation, hosted Native success, Ed25519 release probes or
downloaded public assets. The fixture used isolated storage/preferences and
offscreen in-process windows, without external computer control or real notes.
No new manual QA, displayed system-cursor capture, physical IME/stylus/iPad,
older macOS, provider delivery or updater installation result is claimed.

## v1.2.1 heading-allocation investigation — 5 November 2026

The following pre-fix runs followed the unpublished 1.2.0/build 2018 failure.
The original `v1.2.0` tag and build 2018 remain reserved. Later owned native
heading controls and their verified results are recorded above. The user's
manual QA applies to the initial isolated 1.2.0 candidate, without a new manual
pass for these later native-input changes.

The investigation retained the original heading-height tolerance, sheet-switch
drift limit, minimum post-turn observations, sampling window and timeout. Added
heading repetitions process only the normal run loop; they do not force layout,
click the page or change unrelated preferences. Native allocation checks inspect
actual title/tag frames as well as the editor viewport. Healthy frame logging
does not query font/cell sizing metrics; failure snapshots capture all frames and
state before querying those metrics. A later recovery cannot convert an earlier
failed observation into a pass.

| Source / Native run | Observed result |
| --- | --- |
| `933bce66` / [42018290677](https://github.com/icode100/iNotes/actions/runs/42018290677) | Diagnostic run passed; baseline/restored viewport height 382 points, hidden 534, title 34. This did not establish a fix. |
| `3c7bcd46` / [42019767732](https://github.com/icode100/iNotes/actions/runs/42019767732) | Heading repetitions passed; later sheet switching retained a 21-point viewport drift with stable probe identity and no collapse events. |
| `dad48d47` / [42021928675](https://github.com/icode100/iNotes/actions/runs/42021928675) | Heading cycle 10 retained viewport height 361 instead of 382 through a passive one-second follow-up. |
| `30fd6c4e` / [42023202047](https://github.com/icode100/iNotes/actions/runs/42023202047) | All-field diagnostic run passed 802 editor / 664 workspace checks and iPad compilation; no runtime correction was present. |
| `1def2cbb` / [42025617036](https://github.com/icode100/iNotes/actions/runs/42025617036) | All 100 heading repetitions passed, then full-page exit failed its independently hidden heading/sheets assertion. |
| Unchanged v1.1 `7946a931` / [42027214828](https://github.com/icode100/iNotes/actions/runs/42027214828) | The same full-page exit assertion failed on macOS 26.7.2 (25G332), image `20261102.0473.1`. This establishes a baseline reproduction, not its cause. |
| `a7a76638` / [42027587653](https://github.com/icode100/iNotes/actions/runs/42027587653) | Tags had a native 34-point frame despite its 10-point font and 13-point cell height; title remained 34 and viewport became 361. |
| `09d460ee` / [42029638895](https://github.com/icode100/iNotes/actions/runs/42029638895) | Fixing only the outer Tags frame exposed the inverse: title native frame 13 despite its 28-point font and 34-point cell height; viewport became 403. |
| `14484535` / [42030903619](https://github.com/icode100/iNotes/actions/runs/42030903619) | Constraining both outer frames held viewport height at 382, but Tags still overflowed its 13-point wrapper with a native 34-point frame at cycle 22. The added allocation assertion correctly failed. |

The last mismatch also reproduced locally on macOS 27.2 (26B123): title had a
13-point frame at cycle 18 while the viewport remained stable. These observations
establish incorrect native allocations and show why outer frame constraints were
insufficient; they do not prove an internal SwiftUI/AppKit cache mechanism.
The replacement must pass field-local typing, Unicode/trailing-space title
handling, selection, direct UndoManager undo/redo, focus, read-only and composition
regressions as well as the existing workspace suite. In-process fixtures do not
establish physical IME, displayed system cursor or stylus behavior.

## v1.2.0 exact-source Native checks — 5 November 2026

Source [`ca051953`](https://github.com/icode100/iNotes/commit/ca051953ff5e89239ed1bbed51ac033e02df5e35)
passed [Native checks 42014303977](https://github.com/icode100/iNotes/actions/runs/42014303977).
The run used macOS **26.6.2 (25G83)**, `macos-26-arm64` image
`20261026.0455.2`, Swift **6.3.3** (`swiftlang-6.3.3.1.3 clang-2100.1.1.101`),
Xcode **26.6** and iPhoneSimulator SDK **26.5**.

- **126 XCTest tests, zero failures**, 8.975 seconds (9.002 seconds wall time).
- ARM64 optimized Mac packaging passed. Native diagnostics passed **802 editor**,
  **520 workspace**, **31 equation**, **12 ruled-text**, **8 shortcut** and
  **62 numbering/title/store** checks, plus store/updater, **16 updater
  configurations** and independent backup integration.
- Mounted-DMG verification passed checksum, strict ad hoc bundle/helper/framework
  signatures, ARM64, deployment target, Applications link, all twelve scenery
  hashes, math resources, adaptive icon/fallback and plain persistence smoke checks.
- iPad simulator compilation reported **BUILD SUCCEEDED**. The logged AppIntents
  metadata warning reported that no AppIntents.framework dependency was present;
  this compilation does not establish physical-device behavior.
- Six sheet-switch observations each retained **13 total / 12 post-turn samples**,
  stable probe identity, zero measured drift and no collapse events. The injected
  first-turn stall had a **0.871727625 s** maximum sample gap; late samples do
  not establish continuity during that unsampled interval.
- The 49,127-node hierarchy import measured **2.827 s**, with folder query
  **0.083 s**. Logged disk sizes were rounded `du` results: **40M app**, **33M
  DMG**, **1.5M Sparkle**; these are neither exact file-byte counts nor RAM.

These passing results apply to this source and this Native-check build, not the
separately built release attempt below. They do not establish actual displayed
cursor captures, physical stylus/Pencil, older macOS, real cloud delivery or an
updater installation. Temporary evidence is
`/private/tmp/inotes-v1.2-native-evidence.json` and
`/private/tmp/inotes-v1.2-native-logs.zip`.

## v1.2.0 / build 2018 signed release failed before publication — 5 November 2026

[Signed release run 42015405171](https://github.com/icode100/iNotes/actions/runs/42015405171)
used fresh counter **16**, build **2018**, tag `v1.2.0`, and exact source
`ca051953ff5e89239ed1bbed51ac033e02df5e35`. Its runner logged macOS
**26.6.2 (25G83)** and image `macos-26-arm64` `20261026.0455.2`.

The release repeated **126 XCTest tests, zero failures**, in **12.917 seconds**
(12.955 seconds wall time), built the ARM64 app/DMG and passed the build's plain
smoke checks, including **62 numbering/store** and **16 updater configuration**
checks plus independent backup integration. The hierarchy fixture measured
**3.545 s** import and **0.070 s** folder query. The build's disk-image checksum
verification passed.

The subsequent native verification exited **1** with the exact failure:
“Workspace diagnostic failed: restoring the heading restores its previous
layout height”. Before that failure, **802 native editor**, **31 equation**,
**8 shortcut** and **12 ruled-text** checks passed. No completed workspace-suite
pass is claimed for this release attempt. Ed25519 appcast preparation/signature
probes and publication did not run. No public 1.2.0 release assets were created,
so no independent public-asset result exists. Preserve the tag and build
reservation; do not rerun changed source with build 2018.

The earlier passing Native run and initial user QA do not establish the cause of
this release-only observation or a fix. Added logging is diagnostic evidence
only until the new exact source is validated. The concise failure record is
`/private/tmp/inotes-v1.2-release-summary.json`.

## v1.2.0 local QA and publication preparation — 5 November 2026

Source candidate based on `150d5466abcd8608f7a46ba07fa227585f50eb52`.
This is not yet a published release. The user authorized building/opening an
isolated QA app, with no computer control. On **5 November 2026**, the user
confirmed that the QA app works and explicitly requested GitHub publication.
That satisfied the manual-QA and publication-authorization gate for the initial
candidate. The later exact-source Native pass and release run 16 failure are
recorded separately above. This historical QA record does not claim that
**1.2.0 / build 2018** was published or that a later-source candidate passed.
The candidate changes paper/ink preferences, immediate blank-sheet creation,
inline titles, Mac keyboard zoom and default fit-to-width. No archive format,
dependency, pressure, pane policy or update-signing identity changes.

Host: macOS **27.2 (26B123)**, Apple silicon, Apple Swift **6.4.2**
(`swiftlang-6.4.2.1.9 clang-2100.4.1.1`), Command Line Tools selected at
`/Library/Developer/CommandLineTools`.

- `TMPDIR=/private/tmp bash scripts/test.sh` passed **126 tests, 0 failures**
  in **3.67 seconds**, using the CLT standalone runner's same XCTest methods.
  New coverage includes scenery/legacy preference resolution, fixed papers,
  neutral pitch guides, all-paper contrast and canonical ink preservation.
  The first sandboxed run could not create 25 temporary backup fixtures; the
  unchanged suite passed outside that restriction. No test guard was weakened.
- Shell syntax checks and the iPad project plist lint passed. These do not
  establish iPad compilation.
- `bash scripts/build-macos.sh` stopped before packaging because full Xcode's
  `actool` is unavailable. `bash scripts/verify-macos.sh` found no v1.2 installer.
  `xcodebuild ... -destination 'generic/platform=iOS Simulator'
  CODE_SIGNING_ALLOWED=NO build` could not run with CLT selected.
- Appcast preparation stopped because the release DMG was absent. Signature
  probes require that final DMG/feed and have not passed for this candidate.
  No private key was printed or regenerated, and nothing was uploaded.

After the final source freeze, an ARM64 optimized Mac build passed using SwiftPM
with `--build-system native --disable-sandbox --jobs 4 -c release --arch arm64`
and workspace-local caches/scratch. The existing SwiftMath resource-lookup patch
was applied only in the disposable dependency checkout, as in release packaging.
The build logged existing Swift 6.4 actor/Sendable warnings in navigation code
under the project's Swift 5 mode; it completed successfully in **24.48 seconds**.

The isolated QA binary passed `--smoke-test --editor-test`:

- **803 native editor**, **520 workspace**, **31 equation**, **12 ruled-text**,
  **8 tool-shortcut** and **62 numbering/title/store** checks; existing
  store/updater checks, including **16 updater configurations**, and independent
  backup integration also passed.
- New native coverage includes initial width fit, passive viewport resize,
  clipped backing width, explicit zoom retention and reset, keyboard zoom,
  editor/focus/caret/undo/content preservation, all 23 paper renderings, canonical
  custom colors, and in-gamut/extended/Display P3 picker conversion. Title-store
  checks cover blank defaults, repeated Unicode renames, clearing, numbering,
  complete image-bearing page preservation and save/reopen.
- The 49,127-node hierarchy import completed in **1.005 s**, with folder query
  **0.018 s**. These are this host's diagnostic measurements.
- Sheet-switch samples retained the minimum 12 post-turn observations and showed
  **zero measured frame drift/collapse changes** with stable probe identity.
  The injected first-turn stall produced a **0.743 s** first sample gap; late
  observations do not establish continuity through that unsampled interval.

These are in-process native fixture diagnostics with isolated storage/preferences,
not external computer control, actual displayed-hover captures, interactive
color-panel/menu testing or physical stylus validation. No pane diagnostic
threshold or production pressure behavior was weakened.

QA app: `dist/iNotes-QA-1.2.0.app`, version **1.2.0 / QA build 1**, separate
identity **`io.inotes.qa.v120.20261105`**, with no Sparkle configuration.
Its plist and launch environment point to
`/private/tmp/inotes-v1.2-qa-p6eobxe5`; creation of that isolated `Library.json`
was verified after launch. The app was opened for user QA without computer
control. The user confirmed that this QA app works on **5 November 2026** and
authorized publication. This is the user's aggregate manual result, without a
separate claim that physical stylus, cloud delivery or every supported OS was
tested. Production notes were not used by the automated checks.
ARM64 architecture and strict ad hoc app/framework/helper signatures passed.
The QA app uses the fallback ICNS; it does not verify the adaptive icon,
release DMG, Ed25519 release signatures or separately built public assets.

QA executable: **6,339,552 bytes**, SHA-256
`718a79abff20ca05e7f578d69000332fbff3961310de88b6bc25a2baa57aaa58`.
The app contains **39,807,789 regular-file bytes** excluding duplicate symlink
targets; these are file sizes, not RAM measurements. The source/manifests
fingerprint is
`f4f179a45ba578373ca04e200b950a990d9821837608615a982e176db4ddf1c3`
(SHA-256 over `git ls-files Sources Package.swift Package.resolved` entries,
each path, NUL, file bytes, NUL). No source file was newer than the QA executable.
Temporary logs are `/private/tmp/inotes-v1.2-core-tests.log`,
`/private/tmp/inotes-v1.2-qa-build.log`,
`/private/tmp/inotes-v1.2-native-tests.log` and
`/private/tmp/inotes-v1.2-qa-package.log`; artifact metadata is in ignored
`dist/qa-v1.2.json`.

The user-facing QA checklist for this candidate was:

| Area | Required check |
| --- | --- |
| Matching paper | Every scenery in light/dark; dark Ruby Hills is maroon-black; Forest preference resolves to Nature |
| Fixed paper | Vintage White/Black, Pitch White/Black and all five pastels; visible checked menu state; pitch dots/rules/grid stay grey |
| Ink | All presets and custom picker, change themes, draw, undo/redo and relaunch; original colors/content persist |
| Title | New sheet without a dialog, multiword/Unicode input in underlined title, clear to blank, 256-character paste, title-local Select All and tool-letter typing |
| Zoom | Initial fit to actual editor width, Command-Plus/Equals/Minus, pinch zoom, Fit Page Width, narrow/expanded panes, explicit zoom retained after theme/pane changes |
| Existing safeguards | Text/ink/images/objects together, whole-page Select All from all tools, cursor appearance, pane hide/show/sheet switches, numbering and persistence |

Do not infer visible cursor/menu correctness or physical stylus behavior solely
from callback/in-process checks. Physical tablet/Pencil, iPad, older macOS and
cloud delivery remain separate. The later exact-source Native pass and failed
release attempt are recorded above; no public 1.2.0 assets were published.
The user's publishing authorization does not establish hosted or public-asset
results for later source.

## Published v1.1.0 / build 2017 — 4 November 2026

Released source [`7946a931`](https://github.com/icode100/iNotes/commit/7946a931c8283e5fc0429fbd1d400f22d76312a5)
passed [exact-source Native checks 41830398706](https://github.com/icode100/iNotes/actions/runs/41830398706):
**122 XCTest tests, zero failures** (12.378 seconds), Mac release packaging,
**392 editor, 448 workspace, 31 equation, 12 ruled-text, 8 shortcut and 49
numbering/store checks**, plus 16 updater-configuration checks, store and
independent backup integration.
The mounted installer passed its signature, resource and persistence checks,
including all 12 original scenery hashes. iPad simulator compilation passed for
ARM64 and x86_64. Native-check tools were macOS 26.6.2 (25G83), Swift 6.3.3,
Xcode 26.6 and iPhoneSimulator SDK 26.5. Sheet-switch diagnostics retained their
minimum 12 post-turn samples and reported zero observed drift/collapse events;
logged sampling gaps, including the injected first-turn stall, do not establish
continuity across the unsampled intervals.

[Signed release run 41831928682](https://github.com/icode100/iNotes/actions/runs/41831928682)
**passed**, using fresh counter 15 and build `2002 + 15 = 2017`. It repeated
122 XCTest tests with zero failures (9.822 seconds), packaging, 392 editor/448
workspace/31 equation/12 ruled-text/8 shortcut/49 numbering checks, existing
store/updater and backup integrations, mounted verification and all five
update-signature probes before publishing the new v1.1.0 release. Its runner
logged macOS 26.6.2 (25G83), image `macos-26-arm64` version `20261026.0455.2`;
the release log did not print exact compiler/SDK versions. The tag points to
`7946a931c8283e5fc0429fbd1d400f22d76312a5`.

Independent downloaded-public-asset verification on macOS 27.2 (26B123) passed:

- The versioned and default latest feeds matched the release asset bytes on
  their first readback, advertised **1.1.0 / build 2017**, and enclosed the
  matching HTTPS installer with its exact byte length.
- The public installer matched its published SHA-256 checksum and GitHub asset
  digest. Feed/archive Ed25519 verification and all five valid, changed-feed,
  unsigned-feed, changed-archive and wrong-key probes passed against the
  committed public key.
- Read-only mounted verification passed strict ad hoc app/framework/helper
  signatures, ARM64 architecture, deployment target, Applications link, native
  adaptive icon, all 12 scenery hashes, math resources/licenses and plain
  store/backup smoke checks. Version **1.1.0**, build **2017** and identity
  `io.inotes.app` were explicitly verified. The downloaded binary's 49,127-node
  import took **1.116 s**, with indexed folder query **0.021 s**.
- The original v1.0.4 tag and all seven prior release assets retained their
  recorded identities, sizes and digests. The new release added separate
  assets; no old installer or signed feed was replaced.

Public installer `iNotes-1.1.0-arm64.dmg`: **34,410,451 bytes**, SHA-256
`61d36bfec975170f84eda29d8a1958499c2de359d303bd97335ed74237a8a117`.
The app contains **41,133,627 regular-file bytes**; its executable is
**6,166,608 bytes**, SHA-256
`17bf11650c76fde7c989b4d09ecd932f563b53e8fd00f7b0670226c7c3955353`.
The **1,268-byte** appcast SHA-256 is
`82e88cdaacac613b516465ebdc241749b8ed0d769054740103dedf7c1f489f73`.
These artifact sizes do not measure RAM. The verified public installer/checksum
were copied to `dist/iNotes-1.1.0-arm64.dmg` and its `.sha256` companion; this is
the downloaded public build, separate from the locally compiled QA apps.

Evidence is `/private/tmp/inotes-v110-ci-final-logs`,
`/private/tmp/inotes-v110-ci-final-verification.json` and
`/private/tmp/inotes-v110-release/{verification.json,hosted-complete-log.txt,signature-probes.log,mounted-dmg-verification.log}`.
The user passed the initial local candidate QA and then requested the Pen-only
Extra Broad increase to 1.5 mm. That numeric correction received compilation,
plain smoke and hosted native checks; no second manual pass is claimed. The
candidate and correction records below preserve their status at the time.
No local computer control, interactive UI automation, editor harness or simulator
launch was used. The installed app and real notes were not modified. Actual
updater installation, physical stylus/iPad, older macOS and real provider
delivery remain unverified for this build. Distribution remains ad hoc signed,
not Apple notarized. At that publication, the next fresh signed-release run was
**16**, targeting build **2018**; build 2017 remained reserved. The later run 16
failure is recorded above.

## v1.1.0 final Pen width correction — 4 November 2026

The user reported **all manual checks passed** in the isolated local candidate,
then requested only Pen Extra Broad increase from 1.3 to **1.5 mm**. Pencil and
Straight Line remain **1.3 mm**; Brush/Marker remains **2 mm**. The final numeric
mapping and the existing native width diagnostic were updated. The user's
manual result applies to the tested candidate before this final Pen correction;
it is not a claim of a second manual pass or physical-stylus validation.

The original QA app and its test notes remain intact. The corrected source
compiled incrementally in **2.32 s**. `dist/iNotes v1.1 QA 2.app` has isolated
identity `io.inotes.v110-qa2-20261104`, QA build **2**, disposable notes and no
updater. Its strict app/helper signatures, ARM64 architecture and 12 artwork
hashes passed, along with plain storage/backup smoke checks and 49 numbering
checks. The 49,127-node import took **1.520 s**, query **0.043 s**. The executable
is 10,104,512 bytes, SHA-256
`72ad1a6ef3d082b32572bc895cbe05796ff9e9077e8272614137349ed819988c`;
the app contains 43,572,662 regular-file bytes. These are Debug artifact sizes,
not RAM measurements. No local UI diagnostics or computer control ran.

Evidence is `/private/tmp/inotes-v110-final-build.log`,
`/private/tmp/inotes-v110-final-package.log`,
`/private/tmp/inotes-v110-final-smoke.log` and
`/private/tmp/inotes-v110-qa2-20261104/{verification,source-inputs}.json`.
Exact-source hosted checks and release publication remain pending. The release
build reservation is still 2017; Native checks do not advance the signed-release
workflow counter.

## v1.1.0 / planned build 2017 candidate — 4 November 2026

Candidate based on `ec903e4e3f57b07cb4d3697a6ded78e6fddc99d2`, with the compiled
source snapshot identified by `/private/tmp/inotes-v110-qa-20261104/source-inputs.json`.
Arctic, Open Skyscape, Ruby Hills and Nature replace Forest; Coast and Alpine
remain. A persisted Forest preference resolves to Nature throughout the scenery,
accent and checked-menu paths. Extra Broad follows Broad at 1.3 mm for
Pen/Pencil/Straight Line and 2 mm for Brush/Marker. Existing Fine defaults,
Highlighter choices, custom widths and stored strokes retain their prior paths.
No production storage, numbering, selection, undo, cursor/input or native pane
layout code changed. This scope review is not proof of absence of regressions.

Local results on macOS 27.2 (26B123), Swift 6.4.2 Command Line Tools:

- `bash scripts/test.sh`: **122 standalone tests, zero failures, 3.85 seconds**
  with native file access and temporary test directories. The first sandboxed
  attempt reported 25 backup-file-coordination failures; no test or safety
  assertion was weakened. Numbering, archive compatibility, mixed payloads,
  backup retention, bounded file reads and hierarchy-query regressions remain.
- Native SwiftPM Debug compilation of the frozen source passed in **34.44 s**,
  using `--disable-sandbox`, `--jobs 4` and the pinned SwiftMath resource lookup
  patch only in the disposable dependency checkout. Existing Sendable warnings
  in tool shortcuts/workspace restoration and the native-build-system
  deprecation warning remain. No dependencies or deployment targets changed.
- The signed isolated QA app passed plain `--smoke-test`: store/updater checks,
  **49 numbering/store checks**, independent backup integration, exact
  save/reopen and mixed-payload preservation. Its 49,127-node leaf-first import
  took **1.541 s** and indexed folder query **0.041 s**. No editor/UI harness ran.
- Strict ad hoc app/framework/helper signatures, ARM64 executable, QA bundle
  identity, temporary-library setting and absent updater keys passed. The
  artwork verifier passed all **12** bundled original PNG hashes/dimensions;
  the eight new images match the supplied files byte-for-byte. Scenery is
  **30,143,035 bytes**, an increase of **10,965,704 bytes** from the six old
  images. The bounded native image cache remains unchanged.
- Shell syntax, iPad project/Info plist syntax and `git diff --check` passed.
  Full `build-macos.sh` stopped at missing full-Xcode `actool`; the iPad build
  stopped because `xcodebuild` requires full Xcode. Local DMG verification and
  signed-appcast/signature regression checks are deferred until a full package
  exists. The QA icon needed native tool access after sandboxed `iconutil`
  rejected its otherwise valid iconset; final native packaging/signing passed.

The local app is `dist/iNotes v1.1 QA.app`, identity
`io.inotes.v110-qa-20261104`, version **1.1.0**, separate **QA build 1**. It has
a fresh mixed-content notebook in `/private/tmp/inotes-v110-qa-20261104/library`,
separate preferences and disconnected updater. The app was not opened for UI
testing. Launch and manual instructions are in `dist/Launch iNotes v1.1 QA.command`
and `dist/v1.1-QA.txt`. The executable is **10,104,512 bytes**, SHA-256
`13519627426d55cd3e36879de491d3ed829e01d77280c12cc7b16449a7e1bd61`;
the app has **43,572,656 regular-file bytes**. These Debug QA sizes do not measure
release installer size or RAM. The manifest is
`/private/tmp/inotes-v110-qa-20261104/verification.json`.

Evidence: `/private/tmp/inotes-v110-core-native.log`, `inotes-v110-build.log`,
`inotes-v110-qa-smoke.log`, `inotes-v110-package-qa-native.log`,
`inotes-v110-packaging.log` and `inotes-v110-ipad.log` in the same `/private/tmp`
directory. Mac/iPad scenery and nib diagnostics were extended and Mac diagnostics
compiled, but no local `--editor-test`, simulator launch, computer control or
interactive UI automation was used. Actual displayed cursor, menu checkmarks,
theme transitions, pane geometry, stylus/iPad, older macOS and provider delivery
remain unverified for this candidate.

User manual QA and exact-source hosted Native checks are pending; **v1.1.0 has
not been published**. Public-feed/workflow preflight on 4 November 2026 confirmed
1.0.4/build 2016 and release counter 14. Fresh run 15 reserves build 2017; recheck
before publication. Existing release tags, installers and signed feeds remain
unchanged.

## Published v1.0.4 / build 2016 — 3 November 2026

The user confirmed both fixes in the isolated QA app and authorized publication.
Released source [`c3e7069`](https://github.com/icode100/iNotes/commit/c3e7069e8b5f82455629d33c1b23e14c8515a9bd)
passed [Native checks 41655595986](https://github.com/icode100/iNotes/actions/runs/41655595986):
122 XCTest tests, Mac release packaging, **392 editor, 406 workspace, 31 equation,
12 ruled-text, 8 shortcut and 49 numbering/store checks**, existing store/updater
and backup integrations, mounted installer verification, and ARM64/x86_64 iPad
simulator compilation. Hosted tools were macOS 26.6.2 (25G83), Swift 6.3.3,
Xcode 26.6 and iPhoneSimulator SDK 26.5. The corrected Select All fixture checks
the actual offscreen window's responder chain without assuming global key-window
ownership; it retains the content, undo and unrelated-field assertions.

[Signed release run 41657334792](https://github.com/icode100/iNotes/actions/runs/41657334792)
was fresh counter 14, producing build `2002 + 14 = 2016`. It repeated 122 tests,
packaging, the complete native suite, mounted verification and all five
update-signature checks, then uploaded and verified the distinct installer and
checksum, recorded the source commit, and replaced the signed feed last.
**The workflow concluded failure:** its bounded 120-second readback continued
receiving cached feed bytes. No binary was rebuilt or reuploaded, no new release
run was started, and no signed feed was edited to work around that result.
Independent downloaded-public-asset checks subsequently established successful
publication:

- Both versioned and default latest feed URLs returned identical bytes matching
  GitHub's new asset digest and advertising **1.0.4 / build 2016** with the exact
  build-numbered HTTPS installer enclosure and byte length.
- The downloaded installer matched its SHA-256 file and API asset digest.
  Ed25519 feed/archive verification and all five valid, tampered, unsigned and
  wrong-key signature checks passed against the committed public key.
- Read-only mounted verification passed ARM64, strict ad hoc bundle/helper
  signatures, deployment target, Applications link, adaptive icon, scenery
  hashes, math resources/licenses and plain persistence/store/backup smoke
  checks. A separate metadata check explicitly asserted the app's version 1.0.4,
  build 2016 and `io.inotes.app` identity. The downloaded binary's 49,127-node
  import took 1.033 seconds and folder query took 0.020 seconds.
- Preservation checks confirmed the original annotated v1.0.4 tag object
  `3c1121e75bb1588127c48be7729333676631619b` still peels to
  `d7338419042a4512c569af992ab2384fc088762d`. All four previous build-2012 and
  build-2015 installer/checksum asset IDs, sizes and SHA-256 digests remained
  unchanged; only the new installer/checksum were added and the feed replaced.

Public installer `iNotes-1.0.4-build2016-arm64.dmg`: **24,648,457 bytes**, SHA-256
`fb6cb2bb73b3da2b43ec55f2681e8693eb765b213222eccc1babf708cd24f215`.
The app contains 30,164,149 regular-file bytes; its executable is 6,164,768 bytes,
SHA-256 `88064745ca56bebbfaf8fd556ceb28d30c477a108d1edad017b9addd6363ab8c`.
The 1,278-byte appcast SHA-256 is
`ecc78a7e9c0fec299d592721c25e1f3862b9f9408e07162f3b8b5725e2acf728`.
These are artifact sizes, not RAM measurements.

Independent verification used macOS 27.2 (26B123), Swift 6.4.2 and disposable
libraries. Evidence is under `/private/tmp/inotes-release2016`: hosted logs in
`logs-41655595986` and `logs-41657334792`, downloaded files in `public`, and
`public-signatures.log`, `public-installer.log`, `verification.json` and
`preservation.json`. No local interactive UI harness or computer control was
used; the installed app and real notes were not modified. Actual updater
installation, physical stylus/iPad, older macOS and real provider delivery remain
unverified for this build. Distribution remains ad hoc signed, not Apple
notarized. The next fresh signed-release run is 15 and must produce build 2017
or higher; build 2016 remains reserved despite its workflow's cache timeout.

## Build 2016 publication preparation — 3 November 2026

The user confirmed that both changes work in the isolated QA app and explicitly
authorized publication on 3 November 2026. This satisfies the combined manual-QA
gate recorded below; no local computer control or interactive UI automation was
used. Physical stylus/iPad, older macOS and real cloud-delivery coverage are not
established by that confirmation.

[Native checks 41653405478](https://github.com/icode100/iNotes/actions/runs/41653405478)
on `136353235a7a975960e07aba6ec28547159ffa88` passed 122 core tests, release
packaging and the plain store/backup smoke checks, including 49 numbering checks.
It stopped in the new Select All diagnostic at action dispatch from the Text
responder; installer verification and iPad compilation were skipped. Publication
has not started. The public feed still advertised 1.0.4/build 2015 and the latest
release workflow counter remained 13 when checked. The next fresh release run
14 is reserved for build 2016; exact-source checks must pass before dispatch.

The diagnostic-only correction resolves the actual offscreen fixture's first
responder and expected native action target, then uses AppKit responder-chain
dispatch. The fixture cannot assume that it owns the application's global key
window. Selection, payload, undo and unrelated-field assertions remain in place;
no production input behavior or user-confirmed QA binary was changed by this
correction. The local native Mac compilation passed; the interactive harness is
left to hosted checks under the user's no-computer-control instruction.

## Page numbering and tool-independent Select All candidate — 3 November 2026

Implementation commit `7a379f0c4f43ccc601fd4508fdc31bada83abc4e`, based on
published-build record `1f7cbd6`. This is an unpublished v1.0.4 / build 2016
candidate. Active sheets are numbered consecutively in saved page order within
their immediate chapter/topic. Deleting the middle page closes the gap; new
pages append, and native list drag reordering updates the numbers. Valid older
libraries with gaps normalize on load without changing IDs, titles, timestamps,
stored array order or page payloads. Trash retains unique archival numbers for
older-reader compatibility. Command-A from any page tool selects the whole mixed
page while keeping the selected tool; unrelated focused text fields keep native
Select All. Image-bearing iPad pages retain their existing read-only restriction.

Local results on macOS 27.2 (26B123), Swift 6.4.2 Command Line Tools, macOS SDK 27.2:

- `bash scripts/test.sh`: **122 standalone tests, zero failures, 3.60 seconds**.
  Numbering regressions cover deletion/reset, reorder/move/update, restore,
  duplication/import, formats 1/2/3, retained mixed payloads, invalid mutation
  rollback, date/number tampering, stale counters and cross-parent Trash
  collisions. The 10,000-sheet folder restore took 0.039 seconds; the 49,127-node
  subtree query took 0.020 seconds. The first sandboxed run hit the existing
  native file-coordination restriction in backup tests; the successful run used
  native access with temporary test folders only.
- The final native SwiftPM Debug Mac build passed with `--disable-sandbox`,
  `--jobs 4`, and caches/scratch under `.build`. The final incremental compilation
  took 3.71 seconds after the initial 32.39-second build. Existing workspace
  concurrency and deprecated build-system warnings remain. The pinned SwiftMath
  resource-lookup patch was applied only to the disposable dependency checkout.
- The final isolated QA app passed plain `--smoke-test`, including **49 new
  numbering/store checks** for delete/reset, native move offsets, folders/Trash,
  invalid or filtered moves, retained sheet selection/content, exact archive
  bytes and save/reopen. Existing store/updater and independent backup integration
  checks passed too. Its 49,127-node import took 1.547 seconds and folder query
  took 0.041 seconds. This command did not run the editor/UI harness.
- Strict ad hoc bundle signature, ARM64 architecture, isolated bundle identity,
  temporary library setting and absent updater keys were verified. Shell syntax,
  iPad project plist syntax and `git diff --check` passed.

The QA app is `/private/tmp/inotes-2016-qa-20261103/iNotes QA.app`, identity
`io.inotes.combined-qa-20261103`, marketing version 1.0.4 and separate QA build 1.
Its disposable library is `/private/tmp/inotes-2016-qa-20261103/library`; fresh
fixtures include three pages plus body text, ink, a movable text box, equation
and PNG image. It has separate preferences, no updater configuration and no
connected production backup folders. The executable is 10,101,520 bytes, SHA-256
`144250a5b241d086883bae067d577c599397c4150632e9e2edacd09eea79c3df`;
the app contains 38,044,783 regular-file bytes. These Debug QA artifact sizes
are not release-DMG or RAM measurements. QA instructions and a verification
manifest are beside the app in `TESTING.txt` and `verification.json`.

Evidence: `/private/tmp/inotes-sheet-number-core-final.log`,
`/private/tmp/inotes-sheet-number-build.log`,
`/private/tmp/inotes-combined-build-final.log`, and
`/private/tmp/inotes-combined-qa-smoke.log`.

`bash scripts/build-macos.sh` stopped at the missing full-Xcode `actool`
preflight; the documented iPad simulator build stopped because `xcodebuild`
requires full Xcode. DMG verification and local signed-appcast/signature
regressions therefore remain deferred. No new DMG, signed update or public asset
was published. Full Mac editor/responder diagnostics and opt-in iPad diagnostics
were extended and compiled where supported, but **not executed**: the user
requested manual UI testing and no computer control. No UI automation was used.
Live Cmd-A/menu/drag behavior, cursor display and physical stylus/iPad checks
remain unverified. Publication of build 2016 awaits the user's combined QA result,
full hosted Native checks on the final source, and the release preflight/feed
and workflow-counter recheck.

## Published v1.0.4 / build 2015 — 2 November 2026

Released source [`7c62227`](https://github.com/icode100/iNotes/commit/7c6222769b5aa44cd985454396cdd39024aad746)
passed [Native checks 41452230322](https://github.com/icode100/iNotes/actions/runs/41452230322):
111 XCTest tests, Mac release packaging, 300 editor/406 workspace/31 equation/
12 ruled-text/8 shortcut checks, store/backup checks, mounted installer verification
and iPad simulator compilation. The hosted environment was macOS 26.6.2 (25G83),
Xcode 26.6, Swift 6.3.3 and iPhoneSimulator SDK 26.5. Its injected-stall switch
collected 12 post-turn observations over 2.284 seconds, with a 0.973-second first
sample delay and zero observed drift. This records coverage gaps rather than
claiming uninterrupted observation.

[Release run 41454707559](https://github.com/icode100/iNotes/actions/runs/41454707559)
(counter 13, build `2002 + 13 = 2015`) passed 111 tests, packaging, the full native
suite, mounted verification and all five update-signature checks. It uploaded
and verified the distinct installer/checksum and replaced the signed feed last.
**The workflow nevertheless concluded failure:** its immediate post-upload
readback received different cached feed bytes. No new binary was generated or
reuploaded to work around this. Subsequent independent public checks below
established that publication had completed successfully. The publication helper's
follow-up change waits a bounded interval for exact signed-feed bytes; it does
not weaken byte/signature checks or alter the already published artifacts.

The follow-up publication helper passed 23 offline control-flow scenarios,
including stale-then-fresh responses at both feed URLs, transient HTTP failure,
bounded failure for persistently stale responses and immediate prepublication
mismatch rejection. Production polling shares a 120-second deadline across both
URLs, with 15-second request caps. Timeout tests shorten only temporary script
copies to one second; mocked network/signature calls establish neither actual
CDN timing nor cryptographic validity. Bash syntax and whitespace checks passed.
Log: `/private/tmp/inotes-publish-rebuild-mock-test.log`.

Independent downloaded-public-asset verification on macOS 27.2 (26B123) passed:

- Versioned and default latest feeds were byte-identical, advertised 1.0.4 build
  2015 and matched GitHub's new appcast asset digest. Ed25519 feed/archive
  verification and all five valid/tampered/unsigned/wrong-key checks passed.
- The public installer matched its checksum, had valid strict ad hoc signatures,
  contained the ARM64 app with version 1.0.4/build 2015, and passed the deployment,
  Applications link, adaptive icon, scenery hash, math-resource/license and
  persistence checks.
- The downloaded binary passed 300 editor, 406 workspace, 31 equation, 12 ruled-text,
  8 shortcut and 16 updater checks, plus store/hierarchy/backup integrations.
  Import of 49,127 nodes took 1.029 seconds; query took 0.021 seconds. Its deliberate
  stall lasted 0.651 seconds; 12 post-turn observations followed within 0.935 seconds,
  with zero observed drift and no pane-collapse events.
- Independent preservation review confirmed the original v1.0.4 tag still resolves
  to `d733841`, original installer/checksum asset IDs and original SHA-256 are
  unchanged, and release notes record the new source commit and build.

Public asset `iNotes-1.0.4-build2015-arm64.dmg`: 24,555,573 bytes, SHA-256
`442b037a0065ebbb15172c881ae8e374ba7ef8f94da258876ef5956ab100fb3f`.
The app contains 30,018,805 regular-file bytes; this is not a RAM measurement.
The 1,278-byte appcast SHA-256 is
`968a65952b278152e94557971f436806bcb0dca6e54a6ed2c4f58c99d113d2aa`.

Evidence: `/private/tmp/inotes-build2015-ci-hosted.log`,
`/private/tmp/inotes-build2015-release.log`,
`/private/tmp/inotes-public-104-build2015-verification.log`,
`/private/tmp/inotes-public-104-build2015/verification.json` and
`/private/tmp/inotes-preservation-report.json`. Checks used temporary libraries;
the installed app and real notes were not modified. Actual updater installation,
real provider upload/deletion propagation, older macOS and physical stylus/iPad
coverage remain unverified for this build. Distribution remains ad hoc signed,
not Apple notarized. The next new release run (14) must produce build 2016 or higher.

## Release run 12 stopped before publication; build 2015 preparation

Source [`9c1fee8`](https://github.com/icode100/iNotes/commit/9c1fee875719e7b69dbf38cfb156ec20fa3a374a)
passed [Native checks 41446989533](https://github.com/icode100/iNotes/actions/runs/41446989533):
111 XCTest tests, Mac packaging, 300 editor/399 workspace/31 equation/12 ruled-text/
8 shortcut checks, store/backup checks, mounted installer verification, and iPad
simulator compilation. Hosted log: `/private/tmp/inotes-backups-ci-hosted.log`.

The [signed release run 41448614734](https://github.com/icode100/iNotes/actions/runs/41448614734)
(counter 12, build 2014) passed core tests and packaging but stopped before any
asset publication. The existing workspace sheet-switch diagnostic got only one
sample in its 0.6-second wall-clock window. It recorded stable probe identity,
no pane-collapse changes and zero measured frame drift; the sample-count
requirement failed. This does not prove unobserved geometry was correct.
The signing seed was removed by the workflow cleanup step. Public build 2012,
its feed and original assets were unchanged. Failure log:
`/private/tmp/inotes-backups-release-run12.log`.

The diagnostic now samples immediately after the switch and then requires at
least 12 genuine post-run-loop geometry observations over at least 0.6 seconds,
with a 5-second timeout. Every early observation, drift measurement and KVO event
is retained. A controlled 0.65-second first-turn stall reproduces the missed-window
case; first-sample delay and sampling gaps are logged even on success. Geometry
tolerances, probe/pane/content/tool/undo checks and presentation-layer motion
tests are unchanged. No production navigation/layout behavior changed.

Local Debug build and the full native harness passed after this adjustment:
301 editor, 406 workspace, 31 equation, 12 ruled-text, 8 shortcut and 16 updater
checks, plus store/backup/hierarchy integrations. The injected stall lasted
0.651 seconds; its switch recorded 12 post-turn observations over 0.962 seconds,
with a 0.742-second initial gap, zero observed drift and no pane-collapse events.
These measurements are explicit about the unsampled gap. Logs:
`/private/tmp/inotes-backups-build2015.log` and
`/private/tmp/inotes-backups-native2015.log`. The 111 core tests had already passed
on the unchanged backup/core sources; full hosted checks will rerun them.

The new run must use build 2015 (counter 13), preserving the failed 2014 slot.
Offline publication-control tests passed 19 mocked scenarios, including build/
version/source-commit guards, collisions, public-byte verification ordering and
best-effort restoration after feed-upload failure. These mocked signature calls
do not establish cryptographic validity. Log:
`/private/tmp/inotes-publish-rebuild-mock-test.log`.

## Backup-retention release preparation, build 2014 — 2 November 2026

The user authorized publishing a same-version v1.0.4 rebuild. Public build 2012
and release-workflow counter 11 were rechecked; QA build 2013 is also reserved.
Defaults now use 2014 and the release offset is `2002 + GITHUB_RUN_NUMBER`, so
the next new workflow run (12) produces 2014 and run 13 produces 2015.

A prepublication source review found a historical-recovery edge case: an
unverified corrupt daily/weekly representative could displace a valid older
copy. Retention now verifies all selected recovery representatives before
deleting alternatives, replans around corrupt files, and stops cleanup if its
verification budget is exhausted. All retained identities are rechecked during
cleanup. Legacy cleanup also stops if a protected older copy changes mid-run.
Three regressions cover these cases, including actual partial-removal reporting.

Final local verification on the same CLT/macOS environment as below:

- `bash scripts/test.sh` with native coordination access: **111 tests, zero
  failures, 2.99 seconds**. Log: `/private/tmp/inotes-backups-core-final.log`.
- SwiftPM Debug Mac build passed. Log:
  `/private/tmp/inotes-backups-build-final.log`.
- A separate temporary release-check app passed the store/hierarchy/backup
  `--smoke-test`, including 16 updater configuration checks. Import of 49,127
  nodes took 1.433 seconds; folder query took 0.044 seconds. Log:
  `/private/tmp/inotes-backups-native-final.log`.
- Release workflow YAML parsed using Ruby; rebuild shell syntax and
  `git diff --check` passed.

The rebuild workflow requires the full reviewed source SHA and refuses moved
branches or reused installer names. It preserves the original tag/installer,
uploads and verifies public installer bytes before replacing the signed feed
last, and attempts to restore original feed bytes if replacement fails.
Hosted and public-asset results will be recorded separately. No additional
manual QA, cloud-delivery or physical-device pass is claimed from publication
authorization alone. The previously opened QA app was left unchanged.

## Bounded backup retention candidate — 2 November 2026

Working tree based on `f997376`; this is an unpublished v1.0.4 rebuild candidate.
Automatic backups and Back up now now share owner-isolated history with the
latest 5, up to 7 UTC daily and 4 UTC weekly recovery points, capped at 500 MiB
where files can be safely removed. The current archive is read back and verified
before pruning; the newest two valid copies remain. Identical snapshots are
skipped. Legacy backups are reviewed and explicitly selected in bounded batches,
with directory/file identity and content revalidation before deletion. Independent
exports, other owners and unknown/corrupt files are preserved. No portable archive
schema, local save cadence, editor/input behavior or dependencies changed.

Verified with Swift 6.4.2 Command Line Tools on macOS 27.2 (26B123):

- `bash scripts/test.sh`: 108 standalone tests, zero failures, 2.76 seconds.
  The 24 new tests cover retention calendars and byte budgets, ownership,
  duplicates, rapid writes and clock rollback, failed verification, corruption,
  cleanup failure/retry, changed files/directories, symbolic links, multibyte
  filenames, protected legacy recovery copies and repeatable bounded cleanup.
  Native file-coordination access is required on this host; the sandboxed run
  encountered the existing NSFileCoordinator restriction. The first native run
  exposed a test-only `/var` versus `/private/var` URL equality issue; the assertion
  now compares canonical paths while still checking exact directory contents
  and unchanged bytes. Log: `/private/tmp/inotes-backups-core-canonical.log`.
- SwiftPM Debug Mac build passed with module caches under `.build`, the native
  build system and `--disable-sandbox --jobs 4`. Existing workspace concurrency
  and deprecated build-system warnings remain. Log:
  `/private/tmp/inotes-backups-build.log`.
- The isolated, ad hoc signed Backup QA app passed `--smoke-test`: store/autosave,
  reopen/import, quit and failed-save protection, 16 updater configuration checks,
  hierarchy regressions, independent backup destinations, persistent owner identity,
  duplicate suppression, bounded rotation, latest content, failure/retry and
  disconnect. The 49,127-node import took 1.438 seconds; query took 0.043 seconds.
  Log: `/private/tmp/inotes-backups-native.log`.
- Strict ad hoc bundle signature verification and `git diff --check` passed.
  QA setup created only disposable data: 24 legacy copies, five managed copies
  after 12 distinct writes, and one permanent example export. The QA app was
  opened for user testing; visual/manual cleanup confirmation is still pending.

The QA app is `/private/tmp/inotes-backup-rotation-qa/iNotes Backup QA.app`, with
separate identity `io.inotes.backup-qa-20261102`, marketing version 1.0.4 and QA
build 2013. It uses a temporary library and a local sample backup folder, not
production notes or connected cloud destinations. Its executable is 9,875,440
bytes, SHA-256 `23ebd809d3aec3fbb05e2c21febd4cc751ae1825be6c79bbc68b66191b04d328`;
the app contains 39,333,783 regular-file bytes. These are Debug QA sizes, not
release-installer size or RAM usage.

`bash scripts/build-macos.sh` stopped at the missing Xcode `actool` preflight.
The documented iPad simulator command also stopped because `xcodebuild` requires
full Xcode. No new release DMG, signed appcast, public asset or iPad SDK result is
claimed. Native editor/cursor checks were not repeated for this backup-only patch;
no UI automation was used. Real provider upload/deletion propagation is untested.
Recheck the public feed and release counter before assigning/publishing the new
build; preserve the existing v1.0.4 tag and build-2012 installer.

## Published v1.0.4 / build 2012 — 2 November 2026

Released source [`d733841`](https://github.com/icode100/iNotes/commit/d7338419042a4512c569af992ab2384fc088762d)
passed [Native checks run 41432882320](https://github.com/icode100/iNotes/actions/runs/41432882320):
unit/integration tests, release Mac packaging, native editor/cursor regressions,
mounted DMG verification and iPad simulator compilation. The
[signed release run 41434302469](https://github.com/icode100/iNotes/actions/runs/41434302469)
(release counter 11) independently passed its build, runtime and signature gates
and published [v1.0.4](https://github.com/icode100/iNotes/releases/tag/v1.0.4) using
the existing signing identity. Its build is `2001 + 11 = 2012`; the next new
release run must use build 2013 or higher, never rerun 11 for a changed binary.

Independent public-asset verification on macOS 27.2 (26B123) passed:

- Downloaded DMG matched the published checksum. CryptoKit verified the appcast
  and DMG against the committed Ed25519 public key. All five valid/tampered/
  unsigned/wrong-key signature checks passed. The default latest-update feed was
  byte-identical to the versioned v1.0.4 feed.
- The mounted public installer passed strict ad hoc signatures, ARM64 and
  version/build checks, Applications link, adaptive icons, exact scenery hashes,
  math resource/license checks and persistence smoke tests.
- The downloaded app passed 300 editor, 399 workspace, 31 equation, 12 ruled-text,
  8 shortcut and 16 updater configuration checks, plus store/backup integration.
  The compiler/SDK-dependent editor count differs from the local QA build's 301.
  Its 49,127-node import took 1.008 seconds; folder query took 0.021 seconds.
- The user reported installing this release through the built-in updater and
  confirmed the updated app looks correct. This is user-reported end-to-end
  upgrade evidence, distinct from automated artifact verification.

The public DMG is 24,378,549 bytes, SHA-256
`8eda79d38634d9cfa95dc430d2668e6dd61587dc2235091fc3333a342b2dd558`.
The app has 29,546,789 regular-file bytes; neither size measures RAM. Public
appcast SHA-256:
`8dd628e8f5605f055f26f58f7b658b98e199b3659464a436d7a0e7d8f6e92e03`.
Verification log: `/private/tmp/inotes-public-104-verification.log`; measurements:
`/private/tmp/inotes-public-104/verification.json`. Tests used temporary libraries
and did not replace the installed app. No new physical stylus/iPad, cloud-delivery,
older-macOS, dependency-CVE, Developer ID or notarization result is claimed.

## Mac pasted images and annotations — 2 November 2026

Working-tree feature based on `e7955c0`, including the sidebar contrast fix below.
Mac sheets accept raster clipboard images and copied image files with Cmd-V in
Text or ink modes. Canonical PNG objects render behind text/ink; Select supports
movement, mixed selections, copy/cut/duplicate/delete and proportional single-image
resizing. PNG/PDF exports include images and annotations. Full-library validation
runs before page transactions; rejected undo/redo retains a retryable history
action, including partially executed groups. Format 3 protects image-bearing
libraries from older apps; image-free libraries remain compatible with format 2.

Verified with Swift 6.4.2 Command Line Tools on macOS 27.2 (26B123), without Xcode:

- `bash scripts/test.sh`: 84 standalone tests, zero failures (2.42 seconds),
  including six new image persistence, legacy, import/duplication, atomic rejection,
  byte/geometry/pixel and clipboard/page-budget tests. Native macOS access was
  needed for the existing coordinated-backup tests.
- SwiftPM Debug Mac build passed using the command/cache configuration recorded
  in the sidebar section below. No dependencies were added; the existing
  SwiftMath resource-location patch was applied to its disposable checkout.
- The final isolated ad hoc signed QA app passed `--smoke-test --editor-test`:
  301 editor, 399 workspace, 31 equation, 12 ruled-text, 8 shortcut and 16 updater
  configuration checks, plus store/hierarchy/backup integrations. The 41 new
  editor checks include private-pasteboard PNG/TIFF insertion, Text menu and Pen
  responder-chain handling, layer/input routing, mixed movement, proportional
  resizing, undo/redo and rejected-history retry. Pixel checks confirm both the
  image and ink in exported PNG and rasterized PDF.
- `git diff --check` passed. iOS-target syntax parsing passed; this is not an
  iPad SDK compilation. Shared iPad source preserves image payloads and makes
  image-bearing sheets read-only with an explicit Mac-only notice.

The final QA executable SHA-256 is
`9b42f84318fccb6963b813b7bcc6035c50fa8f0601886d8dfac608f7b952e9f7`.
The Debug QA app contains 38,687,090 regular-file bytes, including the untrimmed
test resources/framework; its executable is 9,228,736 bytes. These are test-bundle
sizes, not release-installer size or RAM measurements. Logs:
`/private/tmp/inotes-images-core.log`, `/private/tmp/inotes-images-build.log`,
`/private/tmp/inotes-images-native-final.log`. The image export artifact is
`/private/tmp/inotes-images-export.png`. Initial pixel tests exposed an invalid
AppKit bitmap fixture; it was replaced by an explicit sRGB fixture, with separate
checks that normalization preserves its pixels. The final run passed without
the temporary PDF-document-lifetime warning from the earlier test iteration.

The user tested the final QA application and confirmed image pasting and annotation work on 2 November 2026.
The harness does not take application focus or replace the user's clipboard;
native responder-chain checks are not proof of global keyboard dispatch in an
active app. Physical stylus, iPad SDK/runtime, release packaging/DMG, signed-update
artifacts and public-release checks remain unverified/deferred for this patch.

## Mac scenic sidebar contrast — 2 November 2026

Working-tree change based on `e7955c0`: scenic Mac sidebars use opaque secondary
labels and a stronger theme-colored surface over the photograph. This covers
hierarchy headers, folder kinds, add controls and footer statuses. Classic and
iPad retain hierarchical secondary styling. Navigation geometry and editor code
are unchanged.

Verified on macOS 27.2 (26B123), Command Line Tools Swift 6.4.2, without full Xcode:

- `bash scripts/test.sh`: 78 standalone core tests, zero failures. The restricted
  run encountered the two existing coordinated-backup access failures; rerunning
  with native macOS access passed without changing tests.
- `swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --jobs 4 --product iNotes`
  (module caches set under `.build`): passed. Existing Swift concurrency and
  deprecated build-system warnings remain. The existing SwiftMath resource patch
  was applied only to the disposable dependency checkout.
- An ad hoc signed Debug QA app with a separate bundle ID and temporary library
  passed `--smoke-test --editor-test`: 260 editor, 399 workspace, 31 equation,
  12 ruled-text, 8 shortcut and 16 updater configuration checks, plus store,
  hierarchy and backup integration checks.
- `git diff --check`: passed.

The temporary QA executable SHA-256 is
`1b316ccdadce41784cefa5a40a37d3dd2349414b366eb77348b24d47d50585fa`.
Logs: `/private/tmp/inotes-sidebar-tests.log`,
`/private/tmp/inotes-sidebar-build.log`, `/private/tmp/inotes-sidebar-native.log`.
These are local Debug results, not release/DMG verification. Installer packaging,
signed update artifacts and iPad compilation were deferred while full Xcode is
absent. Live visual contrast review is left to the user; Computer Use permission
was unavailable. The native harness checks do not establish rendered label
contrast or physical stylus behavior.
The user subsequently tested this QA app and confirmed the sidebar fix works.

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

### Published build 2011 verification

The [existing v1.0.3 release](https://github.com/icode100/iNotes/releases/tag/v1.0.3)
now includes build 2011 from source
[`a70be63`](https://github.com/icode100/iNotes/commit/a70be63bdba60a52b50f68513293571d28fc9a93).
The uploaded DMG and checksum were downloaded independently and matched the
local bytes. The downloaded DMG passed mounted signature/resource/ARM64 and
store/backup checks before the feed was switched. The versioned feed and default
latest-update URL then matched the signed local feed exactly; CryptoKit verified
both public feed and archive against the committed key. Public feed SHA-256:
`2f1074130addcae9ffde15eae777931ae5f36793add72f390e29b51f1eb4fee6`.
The original tag and build2010 DMG remain intact so cached older feeds still work.

Both exact-source hosted Native checks passed fully:
[main run 41319483349](https://github.com/icode100/iNotes/actions/runs/41319483349)
and [development run 41319483118](https://github.com/icode100/iNotes/actions/runs/41319483118).
Each passed unit/integration tests, Mac packaging, native editor/cursor regressions,
DMG verification, and iPad simulator compilation. This records this commit's
success without rewriting the earlier v1.0.3 CI history. The installed local
1.0.3/build2010 app was left intact for the user's own updater test; no new
end-to-end installation result is claimed.

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
