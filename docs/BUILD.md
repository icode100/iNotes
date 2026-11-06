# Build and distribution

iNotes uses Apple's native UI frameworks and Swift standard libraries. The pinned
open-source dependencies are Sparkle 2.10.1 for signed Mac updates and SwiftMath
1.7.3 for native offline LaTeX math. Both versions are recorded in `Package.swift`
and `Package.resolved`. [SwiftMath](https://github.com/mgriebling/SwiftMath/tree/1.7.3) is compiled from Swift source; it does not add a
web view, JavaScript engine, TeX installation, or dynamic rendering framework.
macOS is the primary shipping target.

## Mac development

Requirements:

- Apple silicon Mac with macOS 14 or later.
- Full Xcode 26 or later, including its command line tools.
- A Swift toolchain compatible with the version in `Package.swift`.

From the repository root:

```sh
bash scripts/test.sh
bash scripts/build-macos.sh
open dist/iNotes.app
```

Command line tools can compile the Swift sources. Installer packaging requires
Xcode's `actool` to compile `Resources/AppIcon.icon`, which contains genuine light
and dark appearances. The build regenerates its pencil layer from the same native
vector code as the ICNS fallback. Full Xcode also provides the iPad SDK and simulator.

## Build an app and drag-to-install DMG

```sh
bash scripts/build-macos.sh
bash scripts/verify-macos.sh
```

The build creates:

- `dist/iNotes.app`: native ARM64 app bundle.
- `dist/iNotes-1.3.0-arm64.dmg`: compressed disk image containing the app, an
  Applications shortcut, and installation instructions.
- `dist/iNotes-1.3.0-arm64.dmg.sha256`: SHA-256 checksum.

Open the disk image and drag iNotes to Applications. The DMG does not install
background services, kernel extensions, browser runtimes, or privileged helpers.
The build script validates the property list, architecture, app signature, and DMG
before publishing outputs. The verification script mounts it read-only and checks
the packaged app and Applications shortcut.

Development defaults now target **1.3.0 / prospective build 2021** for shapes,
connectors and tables. Local QA uses an isolated identity, temporary notes and
a disconnected updater. Fresh Native/release/public verification and a new user
heads-up remain required before publication.

The verified public release is **v1.2.2 / build 2020**, released on 5 November 2026
from source `aa392994ed290e38819a74e0a21f5dad520642a3`.
[Branch Native checks 42041114016](https://github.com/icode100/iNotes/actions/runs/42041114016)
and [main Native checks 42046399201](https://github.com/icode100/iNotes/actions/runs/42046399201)
passed, including iPad compilation.
[Signed release run 18](https://github.com/icode100/iNotes/actions/runs/42046511381)
passed, followed by independent downloaded-public-asset verification: API digests,
checksum, exact latest-feed bytes, Ed25519 signatures and all five tamper probes,
plus read-only mounted bundle/resource/signature and persistence checks.
The verified production bundle is `io.inotes.app`, version 1.2.2/build 2020, with
the existing updater key/configuration and no QA environment overrides.
The public DMG is **34,632,864 bytes**; the app has **41,809,499 regular-file
bytes**. These are file sizes, not RAM measurements. See [validation](TESTING.md)
for checksums, logs and limits; metadata is in `dist/public-v1.2.2/verification.json`.

The user confirmed the initial isolated 1.2.0 QA app works and authorized
publication. Source `ca051953` passed hosted Native checks, but release run 16
failed a heading-restoration assertion before publication. Diagnostics captured
title/tag native height mismatches that outer SwiftUI frames did not resolve.
The owned-input replacement at `adf533e4f4ad190422111e531c8c038e72bbfbb6`
passed [branch Native checks 42035913994](https://github.com/icode100/iNotes/actions/runs/42035913994)
and [main Native checks 42037619009](https://github.com/icode100/iNotes/actions/runs/42037619009),
including iPad compilation. [Release run 17](https://github.com/icode100/iNotes/actions/runs/42037656071),
build **2019**, failed a pane-width assertion before publication while navigation
generation 12 still had one pending completion; its 100 heading cycles retained
the correct native allocations. Preserve the unpublished `v1.2.1` tag and build
2019 as well as `v1.2.0`/2018.

The released 1.2.2 diagnostic correction replaces a fixed 0.4-second settling assumption
with a passive wait for native completion callbacks, bounded at five seconds.
The original pane and geometry assertions remain. This is a harness correction,
without a runtime pane-policy change or a proven native pane fix. No additional
manual QA is implied by the later automated or public-asset checks.

The local QA app uses a separate bundle identity, QA build 1, a temporary library
and no updater. Full installer packaging requires Xcode's adaptive-icon compiler;
a CLT-built QA app is not verification of the public release package.

Published v1.1 (version 1.1.0), build 2017, added four new
scenery themes replacing Forest and an Extra Broad nib preset. Source
`7946a931c8283e5fc0429fbd1d400f22d76312a5` passed exact-source Native checks and
signed release run 15. Independently downloaded public assets passed signatures,
checksum, bundle and plain persistence checks; see [validation](TESTING.md).
The public feed advertised 1.1.0/build 2017 on 4 November 2026. For every later
update, recheck the actual public appcast and choose a greater `CFBundleVersion`;
Sparkle compares build numbers, not just the displayed version.
The release workflow uses `2002 + GITHUB_RUN_NUMBER`: run 12 built 2014 but failed
before publishing; runs 13/14/15 published 2015/2016/2017. Runs 16 and 17 built
2018 and 2019 but failed before publication; run 18 published 2020. The next fresh
run 19 must produce **2021**, subject to a feed/counter recheck. A rerun does not
increase its build number. The local v1.1.0 QA apps use separate
identities, QA builds 1 and 2, temporary libraries and
disconnected updaters. User QA passed the initial candidate; the final Pen-only
1.5 mm correction received compilation, plain smoke and hosted native checks.

The 3 November 2026 changes keep active sheets numbered consecutively in page
order, including after deletion and drag reordering, and make Command-A select
all page content from every tool. User QA and exact-source Native checks passed.
The release workflow failed at its cached-feed readback after publication;
independent downloaded-asset verification confirmed build 2016. See
[validation](TESTING.md) for the measured results and limits. The local QA app
uses a separate bundle identity with QA build 1,
a temporary library through `INOTES_DATA_DIR`, and no configured updater.
Record local results separately from later hosted packaging and public assets.

Build products stay under `dist`, module/package caches under `.build`, and the
temporary native build scratch directory under `/private/tmp`. The scratch
directory is removed after packaging. The script explicitly selects SwiftPM's
native build system and disables SwiftPM's additional subprocess sandbox for
compatibility with this host's command line tools and managed workspace.

## Signing for distribution

By default the script applies a local ad hoc signature. This permits local
development on Apple silicon but is **not** an Apple Developer ID signature or
notarization. Current downloaded public builds use this ad hoc signature too;
Gatekeeper may block their first launch because Apple has not checked them for
malicious software. Install the app into Applications, attempt to open it, then,
if you trust its source, use the per-app **Open Anyway** option in **System
Settings → Privacy & Security**. The [README first-open steps](../README.md#run-on-mac)
follow [Apple's guidance](https://support.apple.com/en-us/102445).

Sparkle's Ed25519 feed/archive signatures establish release authenticity and
integrity, independently of Gatekeeper. They do not confer Developer ID signing
or Apple notarization. Developer ID signing, notarization, and Gatekeeper
acceptance must be configured and verified separately.

A maintainer with an Apple Developer ID certificate can build with:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build-macos.sh
```

To submit to Apple, first configure a `notarytool` keychain profile using Apple's
documentation. Then explicitly provide its name:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-keychain-profile' bash scripts/build-macos.sh
```

Supplying `NOTARY_PROFILE` uploads the DMG to Apple's notary service. No upload is
performed by default. The script waits for acceptance, staples the ticket, and
validates it. Apple Developer enrollment and credentials are not included.

The script embeds the ARM64 Sparkle framework and its updater/installer helpers,
preserves framework symlinks, and signs each helper before signing the framework
and app. Unused sandbox XPC services are removed following Sparkle's documented
procedure. The complete upstream license, including its notices, is bundled as
`Contents/Resources/Sparkle-LICENSE`. See [update releases](UPDATES.md) for feed
configuration, the project signing seed, and the version-tag publishing workflow.

## Native equations and font resources

SwiftMath supports common math-mode expressions, including fractions, roots,
powers, Greek symbols, sums, integrals, and matrices. The equation editor retains
LaTeX source and uses native views for its live preview and page display. Mac
combined-page PNG/PDF export includes the rendered equations and positioned text
alongside handwriting. Full TeX documents, document packages, and arbitrary
macros are outside this renderer's scope. Source length and nesting/command
limits bound parsing before the native renderer is called.

The Mac packaging script snapshots the source and manifests into its disposable
build scratch directory, then resolves the exact dependency versions there. It applies the committed
`patches/SwiftMath-1.7.3-resource-bundle.patch` there so the native font loader finds
`Contents/Resources/SwiftMath_SwiftMath.bundle`. This accommodates SwiftPM's CLI
executable resource accessor while preserving normal signed Mac app structure.
The original dependency checkout and its version pin stay unchanged.

Only the complete Latin Modern math font and its layout tables are needed by
iNotes. `scripts/trim-math-fonts.sh` removes unused fonts from the Mac bundle copy,
reducing the resource payload from approximately 7.1 MiB to 0.8 MiB. It preserves
every glyph of the selected font and all supplied license notices. The SwiftMath
MIT license is also copied to `Contents/Resources/SwiftMath-LICENSE`; the font
bundle retains its GUST/font license files.

The iPad target uses Xcode's normal package-resource integration and includes the
official approximately 7.1 MiB font bundle. Xcode script-sandbox defaults remain
enabled. No runtime download is needed for mathematical fonts on either platform.

## Backup folders and archive compatibility

iCloud Drive and Google Drive connect to independently chosen folders. Bookmarks
retain folder access where supported, and each destination has its own automatic
backup schedule, last-success time, retry state, and disconnect action. Google
backups continue when the iCloud folder is unavailable. The app writes complete,
versioned `.inotes` files and leaves cloud uploading to the selected provider; it
does not include CloudKit, a cloud SDK, server credentials, or concurrent-edit
merging. Real provider uploads and physical-device folder permission behavior
require separate verification.

Managed folder backups use a local-library owner ID persisted in preferences,
separate automatic-history directories, and bounded recent/daily/weekly retention
with a 500 MiB budget. Cleanup verifies the current archive before removing older
copies and preserves the newest two valid recovery points. Independent exports,
legacy root archives and other owners' histories are excluded. Legacy cleanup is
an explicit review/selection operation with file-identity and content checks;
large reviews use bounded batches. This changes backup management, not the
portable archive format, local autosave or provider upload mechanism.

Archive format 2 preserves positioned rich-text boxes and editable equations.
The app reads format 1 libraries with empty object arrays and promotes them to
format 2 when new page objects are added. Old app versions reject format 2 instead
of saving a copy that discards those objects. Moving or pasting a selected text
range creates a positioned rich-text box. Rectangular Select and freehand Lasso
can operate on typed text, handwriting, text boxes, and equations in one atomic
page transaction and undo snapshot.

The 1.3 candidate also reads format 3 (page images) and introduces format 4 for
editable diagrams. It promotes a library only when newer objects are present
and never downgrades after removal. Diagram snapshots, attachment references
and table cells survive archives, copies and mixed page undo. Mac PDF/PNG export
renders them with other page content; iPad displays them read-only. Older apps
reject format 4 rather than saving a copy without its diagrams.

Ruled-page alignment uses native text-layout delegates and per-view geometry.
Body lines and wrapped Unicode follow 28pt ruled rows; larger fonts use whole
row increments. The helper also aligns empty typing and moved text boxes, then
restores natural native layout for blank, grid, or dotted paper. It does not
rewrite stored paragraph attributes or RTF to enforce the display grid.

## iPad

Open `iNotes.xcodeproj` in Xcode 26 or later and select the
shared `iNotes-iPad` scheme.
The target uses the same app sources and the local `NotesCore` package, supports
iPadOS 17 or later, and targets iPad only. Select your development team in Signing
& Capabilities and use a unique bundle identifier when deploying to a device.
No development team or certificate is committed. Choose an iPad simulator or your
connected iPad and run.

For a simulator compilation without signing:

```sh
xcodebuild -project iNotes.xcodeproj -scheme iNotes-iPad \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The base `Resources/iPad-Info.plist` supplies archive type registration; Xcode
generates the remaining application metadata. Opening an `.inotes` archive
imports a copy, rather than editing the provider's file in place. The shared scheme
contains an app build but no separate iPad UI test target; run model tests using
`bash scripts/test.sh` on Mac.

Consult `docs/TESTING.md` for current compiler and device results. A successful
macOS build does not validate iPadOS compilation, signing, or Apple Pencil behavior.
These need full Xcode and physical-device verification. Do not use the Mac DMG on
an iPad.

## Open-source distribution

The source is MIT licensed; preserve the license when redistributing. iNotes is an
independent app, not affiliated with Microsoft, Apple, or Google. Native OneNote
`.one`/`.onepkg` compatibility, Microsoft account integration, and real-time
collaboration are outside the present format.
