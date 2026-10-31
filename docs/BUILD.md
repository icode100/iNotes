# Build and distribution

iNotes uses Apple's native UI frameworks and Swift standard libraries. The one
third-party native framework is Sparkle 2.10.1 for signed Mac updates, pinned in
`Package.swift` and `Package.resolved`. macOS is the primary shipping target.

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
- `dist/iNotes-0.1.0-arm64.dmg`: compressed disk image containing the app, an
  Applications shortcut, and installation instructions.
- `dist/iNotes-0.1.0-arm64.dmg.sha256`: SHA-256 checksum.

Open the disk image and drag iNotes to Applications. The DMG does not install
background services, kernel extensions, browser runtimes, or privileged helpers.
The build script validates the property list, architecture, app signature, and DMG
before publishing outputs. The verification script mounts it read-only and checks
the packaged app and Applications shortcut.

Use `VERSION=0.1.1 BUILD_NUMBER=3 bash scripts/build-macos.sh` to change the version.
Every published update must have a larger build number than its predecessor.
Build products stay under `dist`, module/package caches under `.build`, and the
temporary native build scratch directory under `/private/tmp`. The scratch
directory is removed after packaging. The script explicitly selects SwiftPM's
native build system and disables SwiftPM's additional subprocess sandbox for
compatibility with this host's command line tools and managed workspace.

## Signing for distribution

By default the script applies a local ad hoc signature. This permits local
development on Apple silicon but is **not** an Apple Developer ID signature or
notarization. Gatekeeper behavior on other Macs must be tested with a notarized
release; a development DMG must not be described as ready for public distribution.

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
