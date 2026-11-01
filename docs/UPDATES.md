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

The existing project seed is stored locally at `.private/updates/ed25519.key`,
mode 600, inside a private directory excluded by Git. It is never bundled with
the app. Keep an independent secure backup. Do not delete or regenerate it for
each release: previously installed apps trust the existing public key.

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

```sh
VERSION=1.0.1 BUILD_NUMBER=1008 bash scripts/build-macos.sh
VERSION=1.0.1 bash scripts/verify-macos.sh
VERSION=1.0.1 bash scripts/generate-appcast.sh
VERSION=1.0.1 bash scripts/test-update-signatures.sh
```

The appcast command prepares `dist/update/appcast.xml`. It uses Sparkle's official
`generate_appcast` and `sign_update`, then independently verifies both signatures
using Apple CryptoKit and the committed public key. It does not upload anything.
This example assumes the latest published build is 1007; check the actual
published `CFBundleVersion` and use a larger number. Development defaults
(`1.0.1`, build 1008) are separate from the release workflow's `1000 + GITHUB_RUN_NUMBER`.
The feed points to the matching `v1.0.1` release's DMG. Never edit a signed appcast
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
`v1.0.1`. `.github/workflows/release.yml` runs unit/integration tests, builds the
ARM64 DMG, verifies the mounted bundle, signs and independently verifies the
appcast, then publishes the DMG, SHA-256 checksum, and `appcast.xml` as GitHub
Release assets. Its token has repository-contents write permission only in the
release job. Build numbers use `1000 + GITHUB_RUN_NUMBER`; keep this workflow's
counter and publish versions in ascending order. A missing key fails the workflow
before publication. The normal CI workflow does not publish releases.

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
