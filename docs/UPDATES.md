# Native Mac updates

iNotes uses [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1),
an open-source native Mac updater. It checks daily, downloads verified updates in
the background, and installs on normal quit. **iNotes → Check for Updates…** runs
a manual check. The app saves its notes before an updater-requested restart; a
failed save postpones that restart and leaves the app open. After saving or
exporting a backup, Check for Updates retries a postponed installation.

The release feed is public and requires no account:
`https://github.com/icode100/iNotes/releases/latest/download/appcast.xml`.
It becomes available after the first release is published. Merely pushing a
source commit does not update installed apps; pushing a release tag publishes a
new version through the workflow below.

Both the appcast and DMG must have valid Ed25519 signatures from the project's
public key in `Resources/UpdatePublicEDKey.txt`. Sparkle verifies the archive before
extraction. Feed-signature failures never expire into an unsigned fallback.
Profiling is disabled. A build without a public key keeps the updater dormant;
the menu explains that its release channel has not been configured.

## Project signing identity

For local signing, the existing project seed belongs at
`.private/updates/ed25519.key`, mode 600, inside a private directory excluded by
Git. Hosted releases use the configured `SPARKLE_PRIVATE_KEY` secret and do not
require a local seed copy. It is never bundled with the app. Keep an independent
secure backup. Do not regenerate the identity for each release: previously
installed apps trust the existing public key.

For a new project identity only, `swift scripts/generate-update-keys.swift`
creates an Apple CryptoKit Ed25519 seed in the 32-byte base64 format supported by
Sparkle's `--ed-key-file` option. It does not modify the login Keychain. It refuses
to replace an existing public identity if the private seed is missing or mismatched.
The project validated this format using Sparkle's official signing tool.

Configure the GitHub repository Actions secret **SPARKLE_PRIVATE_KEY** with the
contents of that existing file. Do this through GitHub's secret settings or an
authenticated GitHub CLI using input redirection; never paste the seed into an
issue, commit, build command argument, or release note. The workflow keeps its
temporary key file private and removes it after the job. Configuring this secret
does not publish a release.

## Build and sign a local update

The current release is **v1.2.2 / build 2020**, from source
`aa392994ed290e38819a74e0a21f5dad520642a3`, published on 5 November 2026.
[Branch Native checks 42041114016](https://github.com/icode100/iNotes/actions/runs/42041114016)
and [main Native checks 42046399201](https://github.com/icode100/iNotes/actions/runs/42046399201)
passed, including iPad compilation. [Signed release run 18](https://github.com/icode100/iNotes/actions/runs/42046511381)
passed. Independent downloads then matched the API digests and checksum; latest
and versioned feeds matched exact signed bytes, Ed25519 verification and all five
signature probes passed, and read-only mounted bundle checks confirmed production
identity/version/build, the existing update key and no QA overrides. See
[validation](TESTING.md) for measured artifacts and limits.

The user passed the isolated 1.2.0 QA app and authorized v1.2 publication on
5 November 2026. Source `ca051953` passed hosted Native checks, but signed release
run **16** failed “restoring the heading restores its previous layout height”
before publication. Its v1.2.0 tag and build **2018** remain reserved. Ed25519
release signature probes did not run and no public 1.2.0 assets were published.
The owned Mac heading-input replacement at
`adf533e4f4ad190422111e531c8c038e72bbfbb6` passed both
[branch Native checks 42035913994](https://github.com/icode100/iNotes/actions/runs/42035913994)
and [main Native checks 42037619009](https://github.com/icode100/iNotes/actions/runs/42037619009),
including iPad compilation. Its [signed release run 17](https://github.com/icode100/iNotes/actions/runs/42037656071),
build **2019**, stopped before publication at a pane-width assertion while
navigation generation 12 had one pending native completion. All 100 heading
cycles retained correct native allocations. No public 1.2.1 assets were created;
preserve its tag and build 2019 too.

The released 1.2.2 harness correction waits passively for native completion callbacks,
bounded at five seconds, rather than assuming 0.4 seconds completes an animation.
It retains the original pane/geometry limits and makes no runtime pane-policy
change or claim of a proven native pane fix. Every later source update still
requires exact-source Native checks before tagging, a fresh feed/counter check,
signed release checks and independently downloaded-public-asset verification.

The published v1.1 update uses version **1.1.0** and build **2017**, from source
`7946a931c8283e5fc0429fbd1d400f22d76312a5`. The user passed local manual QA and
requested the final Pen-only 1.5 mm correction. Exact-source
[Native checks](https://github.com/icode100/iNotes/actions/runs/41830398706),
[release run 15](https://github.com/icode100/iNotes/actions/runs/41831928682) and
independent public-asset verification passed; see [validation](TESTING.md).
Local QA apps have separate notes/preferences, QA builds 1 and 2 and no updater.
No local computer control or interactive UI automation is permitted.

The 3 November 2026 release uses build 2016, keeps page numbers consecutive
after deletion and reordering, and supports Command-A for the whole page from
every tool. User QA and exact-source Native checks passed. Release run 14
published the installer and signed feed, then failed its cached-feed readback.
Independent downloaded-asset verification confirmed the published bytes and
signatures; see [validation](TESTING.md). The isolated QA app uses a separate
identity, QA build 1, temporary library, and disconnected updater. Recheck the
public feed and workflow counter before any later publication.

```sh
VERSION=1.2.2 BUILD_NUMBER=2020 bash scripts/build-macos.sh
VERSION=1.2.2 bash scripts/verify-macos.sh
VERSION=1.2.2 bash scripts/generate-appcast.sh
VERSION=1.2.2 bash scripts/test-update-signatures.sh
```

The appcast command prepares `dist/update/appcast.xml`. It uses Sparkle's official
`generate_appcast` and `sign_update`, then independently verifies both signatures
using Apple CryptoKit and the committed public key. It does not upload anything.
For v1.0.3, the security rebuild 2011 exceeds the initial public build 2010 and
shared local builds 1010–1012. Check both published and shared `CFBundleVersion`
values and use a larger number for every update, including same-version rebuilds.
Development defaults (`1.3.0`, prospective build 2021) target the unpublished
diagram feature. They remain separate from the release workflow's
`2002 + GITHUB_RUN_NUMBER`. Run 11 published v1.0.4 build 2012; isolated backup QA
used build 2013. Run 12 built 2014 but stopped at native diagnostic verification before publication.
Runs 13, 14 and 15 published 2015, 2016 and 2017. Runs 16 and 17 built 2018 and
2019 but failed before publication. Run 18 published 2020. The next new release
run (19) must produce **2021**, subject to a feed/counter recheck. Failed builds
2014, 2018 and 2019 remain reserved alongside
original installers and QA slots.
The public feed points to the matching `v1.2.2` release's DMG. Never edit a signed appcast
after generation. Re-run the script if its contents change. The last command
checks valid signatures and rejects changed feeds, unsigned feeds, changed
archives, and a different public key.

Overrides for maintainers:

- `UPDATE_FEED_URL`: HTTPS URL embedded into the app.
- `UPDATE_PUBLIC_ED_KEY`: public key embedded into the app; defaults to the public key file.
- `UPDATE_PRIVATE_KEY_FILE`: local signing seed file used only by the appcast script.
- `UPDATE_DOWNLOAD_URL_PREFIX`: HTTPS release-download prefix for generated enclosures.
- `SPARKLE_TOOLS`: directory containing the pinned distribution's signing tools.

For an explicitly disconnected development build, set `UPDATE_PUBLIC_ED_KEY=''`.
A missing public key keeps the updater dormant. A supplied key requires a valid
HTTPS feed; malformed configured channels are rejected before packaging.

## Publish a version

After reviewing the next source and configuring the secret, push a new
`vX.Y.Z` tag only after publication approval and exact-source Native checks. The user
authorized v1.2 publication on 5 November 2026. Preserve the failed unpublished
`v1.2.0` tag at `ca051953` and `v1.2.1` tag at `adf533e4`; do not move either to
changed source or reuse builds 2018/2019. Published `v1.2.2` identifies
`aa392994`; preserve its build 2020 and use a higher number for an updated binary.
`.github/workflows/release.yml` runs unit/integration tests, builds the
ARM64 DMG, verifies the mounted bundle, signs and independently verifies the
appcast, then publishes the DMG, SHA-256 checksum, and `appcast.xml` as GitHub
Release assets. Its token has repository-contents write permission only in the
release job. Build numbers use `2002 + GITHUB_RUN_NUMBER`; keep this workflow's
counter and publish versions in ascending order. A missing key fails the workflow
before publication. The normal CI workflow does not publish releases.

### Rebuild an existing visible version

The tag-triggered workflow creates new releases. For an explicitly authorized
same-version rebuild, dispatch **Signed macOS release** on the reviewed source
commit with the existing version (for example, `1.0.4`) and its full source commit
SHA. The workflow refuses a branch that moved after review. It preserves the original
tag and installers and publishes a distinct build-numbered DMG/checksum. Do not
delete or force-move a published tag. Start a new workflow dispatch instead of
rerunning an attempt; the counter must advance for a changed binary.

The workflow checks that this is the current stable release and that its new
build number exceeds the public appcast. It runs the build, runtime and signature
checks, uploads the distinct installer/checksum without replacing old assets,
and verifies their downloaded public bytes. It records the new source commit
and build in the release notes, then replaces the signed appcast last and verifies
both versioned and latest public feeds, allowing a bounded wait for GitHub's
post-replacement cache to serve the exact signed bytes. A changed live feed before
publication or an existing installer
name stops publication. Failed feed replacement attempts to restore the original
signed feed bytes. All checks must still be independently confirmed after release.

Full iPad compilation runs in Native checks on source pushes; wait for that exact
commit to pass before dispatching publication. Recheck the public feed and release
counter immediately before publishing. Retain earlier installers so cached feeds
can finish safely. The original version tag continues to identify the original
build, while the rebuild's source commit is recorded in the release notes.

The workflow currently uses ad hoc Apple code signing. Ed25519 establishes update
authenticity; Developer ID signing and notarization are separate requirements for
the normal Gatekeeper install experience on other Macs. For those releases, use
the Developer ID/notarization build options in [BUILD.md](BUILD.md), generate the
feed from that final stapled DMG, and publish those verified assets. No Developer
ID certificate or Apple credentials are committed or fabricated.

The iPad app uses Apple's app distribution/update system; Sparkle is linked only
on macOS. No updater daemon is installed. On the development Mac, the trimmed
ARM64 framework occupies approximately 1.5 MiB on disk; runtime memory has not
been separately benchmarked.

Reference: [Sparkle setup and security](https://sparkle-project.org/documentation/),
[programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[signing and optional XPC removal](https://sparkle-project.org/documentation/sandboxing/),
[publishing updates](https://sparkle-project.org/documentation/publishing/).
