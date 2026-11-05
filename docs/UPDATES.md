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

The v1.2.0 update targets prospective build **2018**. On 5 November 2026, the user
confirmed that the isolated Mac QA app works and explicitly authorized GitHub
publication. Wait for hosted Native checks on the exact source commit before
tagging, and recheck the latest public feed and workflow counter. Build 2018 is
the expected value for fresh release run **16**; signed release packaging and
independent downloaded-public-asset verification remain pending at this stage.

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
VERSION=1.2.0 BUILD_NUMBER=2018 bash scripts/build-macos.sh
VERSION=1.2.0 bash scripts/verify-macos.sh
VERSION=1.2.0 bash scripts/generate-appcast.sh
VERSION=1.2.0 bash scripts/test-update-signatures.sh
```

The appcast command prepares `dist/update/appcast.xml`. It uses Sparkle's official
`generate_appcast` and `sign_update`, then independently verifies both signatures
using Apple CryptoKit and the committed public key. It does not upload anything.
For v1.0.3, the security rebuild 2011 exceeds the initial public build 2010 and
shared local builds 1010–1012. Check both published and shared `CFBundleVersion`
values and use a larger number for every update, including same-version rebuilds.
Development defaults (`1.2.0`, prospective build 2018) target the authorized update and
are separate from the release workflow's
`2002 + GITHUB_RUN_NUMBER`. Run 11 published v1.0.4 build 2012; isolated backup QA
used build 2013. Run 12 built 2014 but stopped at native diagnostic verification before publication.
Runs 13, 14 and 15 published 2015, 2016 and 2017. The next new release run (16)
must produce 2018 or higher. Failed build 2014
remains reserved alongside the original installer and QA slot.
The public feed points to the matching `v1.1.0` release's DMG. Never edit a signed appcast
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

After reviewing the source and configuring the secret, push a tag such as
`v1.2.0` only after the user's publication approval and exact-source Native
checks. The user authorized v1.2.0 publication on 5 November 2026.
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
