# Tilr Mac releases

**Current default workflow:** see [PRODUCTION.md](PRODUCTION.md): `setup-release.command` configures credentials only; `release.command` builds only; `upload.command` publishes the last completed tested pair without rebuilding. Use `release.command --status` to inspect local versions/builds, and `--version` / `--build` to choose them. Full commands and the independent server workflow are in PRODUCTION.md. The combined `--publish` mode below remains an explicit shortcut.

The standard release is **two separate DMGs**, Apple Silicon (`arm64`) and Intel
(`x86_64`), so the user can choose on the website. Agent setup, permissions,
non-interactive execution and recovery are documented in [AGENT_RELEASE.md](AGENT_RELEASE.md).

After the one-time setup, the standard workflow is:

```sh
./release.command --status
./release.command
# Test the printed release artifacts, then:
./upload.command
```

Both builds finish before either is published. Each has its own Sparkle feed;
the command prints both verified download links. Run with `--check --publish`
instead of version/build to check the agent's actual release permissions first.

The first release is the native viewer with a bundled welcome page. It requires
macOS 14 or later, not Node, npm, Homebrew or Xcode on the recipient's machine.
The app bundles a local terminal server; its subsequent updates use an independent signed feed. No preinstalled web/plugin workspace is included.
Existing `site:`, `apps:`, `--site` and `--url` configurations still work.

Install by opening the DMG and dragging Tilr into Applications. Launch the copy
in Applications, not the one on the mounted disk image. The welcome page's
“Use your own interface” section explains how to load a folder with index.html.
Plain HTML/CSS/JS needs no npm; TypeScript/plugin development currently needs
Node >=22.18. Installing plugins with the built-in plugin manager runs the system `git`
(Xcode Command Line Tools) for now; without it the install fails with an error saying so. Files and settings remain outside the signed application bundle.

## One-time release setup

Run `./setup-release.command` once in a normal Terminal to configure the certificate,
Sparkle key and notarization profile. It neither builds nor publishes. Then use
`./release.command` for an automatic build of BOTH architectures, without publication.
It saves only non-secret settings in ignored `release.local.json`, so later releases
need just the non-interactive `release_all.py` command. Requires Python 3.11+, Xcode, Node >=22 and Wrangler
(`npm install -g wrangler`, then `wrangler login` if not already authenticated).
These are publisher tools; recipients do not need them.

Use the paid **Rexuni LLC** Apple Developer team. In Xcode → Settings → Apple
Accounts → Rexuni LLC → Manage Certificates create **Developer ID Application**.
Apple Development and Apple Distribution are not substitutes for direct downloads.
Do not revoke an existing certificate to fix local access issues.

Check that the certificate AND private key are available in the login Keychain:

```sh
security find-identity -v -p codesigning
```

Copy its complete `Developer ID Application: … (TEAMID)` name. Keep the private
key in Keychain, not the repository. If Xcode sees the certificate but an agent's
restricted shell sees zero identities, run the release from your normal Terminal.

Install Xcode command-line tools, Rust (rustup, with `rustup target add aarch64-apple-darwin
x86_64-apple-darwin`) and the plugin manager (gitpm) checkout next to this repo (`../git/gitpm`,
or `GITPM_DIR`), then build its static library and resolve the pinned Swift
dependencies (the binaryTarget must exist before SwiftPM reads the package):

```sh
cd /path/to/tilr/tilr-mac
scripts/build-gitpm.sh --arch arm64 --arch x86_64
swift package resolve
```

`release.py` and `release_all.py` run `scripts/build-gitpm.sh` themselves (a no-op
when up to date). The library is linked statically into `Contents/MacOS/Tilr`: no extra file
in the bundle, nothing extra to sign or notarize.

Sparkle 2.10.0 is pinned in Package.swift and Package.resolved. Its tools live in:

```sh
sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_keys" --account tilr-rexuni
```

This generates an Ed25519 private key in your login Keychain and prints the
**public** key. Back up the private key securely according to Sparkle's docs;
never put it on the CDN or in Git. The Apple code-signing key and Sparkle update
key are separate. Configure notarization credentials interactively (Apple ID
with an app-specific password, or supported App Store Connect API credentials):

```sh
xcrun notarytool store-credentials tilr-rexuni
```

Use the actual Rexuni team ID from Apple; do not copy a team ID from another
project. Do not paste passwords into this document or shell command history.
For the Apple ID flow create an app-specific password at account.apple.com →
Sign-In and Security → App-Specific Passwords. Enter it only at notarytool's secure
prompt. Being signed in to Xcode does not configure notarytool automatically.

## Build a distributable DMG

Feeds live in the existing `tilr-cdn` bucket in Cloudflare account
`8e0530af975a33f2f739127f75084531`, already public as `https://cdn.tilr.dev`:

- Stable Apple Silicon: `https://cdn.tilr.dev/mac/arm64/appcast.xml`
- Beta Apple Silicon: `https://cdn.tilr.dev/mac/beta/arm64/appcast.xml`
- Substitute `x86_64` or `universal` for the matching builds.

No new Worker, backend service, or npm process is needed to serve a feed. These
are static R2 objects. The first successful `--publish` creates the feed. The
Rust core's existing `releases/<platform>/latest` flow is independent.

For manual initial setup configure these in your Terminal (the guided command
does this and saves them to `release.local.json`):

```sh
export TILR_SIGN_IDENTITY='Developer ID Application: YOUR EXACT REXUNI IDENTITY (TEAMID)'
export TILR_NOTARY_PROFILE='tilr-rexuni'
export TILR_UPDATE_FEED='https://cdn.tilr.dev/mac/arm64/appcast.xml'
export TILR_UPDATE_PUBLIC_KEY='PUBLIC KEY FROM generate_keys'
python3 scripts/release.py --version 0.1.0 --build 1 --arch arm64 --publish
```

Increase `--build` on EVERY release, even when the marketing version is unchanged.
The lower-level `release.py --arch` command is available for troubleshooting one
architecture. The normal release uses `release_all.py` to produce two separate
DMGs, not a Universal app. Test each architecture on a matching Mac.

The script builds from source, embeds Sparkle including its helper processes,
signs inside out with hardened runtime and secure timestamps, verifies the bundle,
notarizes and staples the app, creates a compressed DMG with an Applications link,
then signs, notarizes, staples and verifies the DMG. It never launches, replaces
or terminates the user's running Tilr. No App Sandbox entitlement is added.

Omit `--publish` to build without uploading. Output: `build/releases/0.1.0-1-arm64/`,
containing Tilr.app, the DMG, SHA-256 and a `release.json` completion receipt.
An existing release output directory is not overwritten. A failed invocation
can leave intermediate files; only a completed `SIGNED AND NOTARIZED` result is
ready for distribution. There is no silent unsigned fallback.

For local packaging checks without Apple credentials:

```sh
python3 scripts/release.py --version 0.1.0 --build 1 --arch arm64 --preview
```

The resulting `*-preview.dmg` is ad-hoc signed, **not notarized and not a public
release**. The publisher rejects previews. Preview mode omits the feed/public key
even when release settings exist, so its updater is inactive. `--swift-disable-sandbox` is
available when SwiftPM itself is running inside an existing restricted sandbox;
it does not grant network or Keychain access. `--build-package` and `--framework`
allow packaging an equivalent local dependency build; normal releases do not need
these overrides. `--skip-build` packages previously compiled output and should
only be used immediately after a successful matching build.

## Publish a Sparkle update

The app uses SPUStandardUpdaterController and the native “Check for Updates…”
menu. Automatic checks default to enabled (existing user preferences are respected);
Sparkle manages download, signature verification, installation and relaunch. The release
feed and public key are sealed into Info.plist before code signing. No updater
contacts a feed during `--probe` or in unconfigured local builds.

After the first guided setup, publish subsequent releases with:

```sh
python3 scripts/release_all.py --version 0.1.1 --build 2 --channel stable --publish
```

Add `--notes /path/to/changes.txt` for plain-text notes embedded in the feed.
`release_all.py --channel` chooses stable/beta and derives both feeds. The lower-level
single-architecture `release.py` reads the saved feed or `TILR_UPDATE_FEED` override.

`scripts/publish.py` verifies the completion receipt and archive hash, Apple code
signatures and stapled notarization, and checks that the Keychain Sparkle public
key matches the one embedded in the app. It downloads the existing feed (only
HTTP 404 counts as absent), refuses duplicate/older build numbers, uses official
`generate_appcast` to produce EdDSA signatures, and validates the generated URL,
file size, version and signature. Old feed entries are retained; delta generation
is disabled for the initial release workflow.

It then uploads the immutable DMG, downloads it through the public CDN and verifies
its SHA-256, uploads the checksum, and publishes `appcast.xml` LAST with
`no-cache, max-age=0, must-revalidate`. The published feed is downloaded and compared.
An existing DMG with different bytes is never overwritten. Previous archives remain
available. Never run publishers concurrently from different Macs: the lock only
serializes processes on the same checkout/Mac.

The output includes a download URL to send to the designer, e.g.:
`https://cdn.tilr.dev/mac/arm64/Tilr-0.1.0-1-arm64.dmg`. This URL is real only after
successful upload. `published.json` records successful publication; `appcast.xml`
is also saved beside the local release for inspection.

If the build finished but uploading failed, resume without rebuilding/notarizing:

```sh
python3 scripts/release_all.py --version 0.1.1 --build 2 --channel stable --publish --resume
```

To prepare an appcast for one already-built architecture without uploading, use
`python3 scripts/publish.py build/releases/0.1.1-2-arm64`. The publisher accepts an
already-published build only after verifying matching feed metadata, signature and
downloaded archive; newer builds or different bytes are rejected. If a CDN caching rule overrides origin cache
headers, exclude `mac/**/appcast.xml` from that rule before distributing releases.

For a bad release, publish a corrected build with a HIGHER build number, even if
its source code is reverted. Do not replace the old immutable DMG or lower the
version in the feed. Keep the same app bundle ID, feed URL, and signing keys across
normal releases. Key rotation is a separate migration, not a routine release step.

Do not modify a signed DMG or its embedded bundle after generating the appcast.
Rebuild/re-notarize/re-sign the update if any contents change. User configuration
and external dev folders must never be copied back into or deleted with the app.

## Verify before handing off

1. Download the hosted DMG through a browser on a clean Mac/user account; install
   in Applications and launch through Finder. Verify Gatekeeper and offline launch.
2. Confirm welcome page, window controls, and loading/reloading an external site
   without Node. Check a path containing spaces and non-ASCII characters.
3. Install build 1, publish build 2 to a TEST feed, choose Check for Updates, install
   and relaunch. Confirm the new build number and persistence of settings/site data.
4. Confirm a release with the same/older build is not offered. Check invalid update
   signatures are rejected. Keep this test feed separate from public releases.

For beta testing use `release_all.py --channel beta` for BOTH beta versions.
Stable installs do not read these feeds.
The first real 1 → 2 GUI update is still a required acceptance test; script tests
alone cannot prove Sparkle's install/relaunch behavior.

Run checks with `python3 scripts/test_publish.py` and `python3 scripts/test_release_all.py`. They cover altered
archives/previews, wrong destinations/versions, downgrades, HTTP failures, immutable
file conflicts and the requirement to verify the download before exposing the feed.

For native code changes also run `./run.sh --test --probe`. The probe checks the
bundled welcome page when no external site exists; otherwise it checks the web
header. Both paths check window geometry, the palette and Space movement. Never
restart the user's normal Tilr for release verification.

## Next stage

Bundle a version-matched prebuilt web workspace and plugins; then add local
tilrd lifecycle management. Keep bundled code read-only, dev workspaces
external, and coordinate server updates so terminal sessions survive. The server
must not self-update an executable inside the signed .app.

## References

- https://sparkle-project.org/documentation/
- https://sparkle-project.org/documentation/programmatic-setup/
- https://sparkle-project.org/documentation/publishing/
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- https://support.apple.com/en-us/102654
- https://developers.cloudflare.com/r2/get-started/cli/

## Configuration and app folders

The default config is `~/Library/Application Support/dev.tilr.mac/config.yml`.
`--config DIR` overrides its folder, followed by `TILR_CONFIG`. This also selects
an independent instance. `run.sh --test` defaults to the sibling `dev.tilr.mac.test`.

The default `site: apps/default` is relative to the config folder. Both `site:` and
each `apps:` entry accept config-relative paths, absolute paths, and `~/…`.
Use `--site DIR` to open a different web app for one launch (relative command-line
paths are relative to the working directory), for example:

```sh
open /Applications/Tilr.app --args --site "$HOME/projects/dashboard/site"
```

Web installers and Control use the same default config folder and honor
`TILR_CONFIG`; installer `--site` or `TILR_SITE` overrides the install destination.
With multiple `apps:` entries, select the install destination with `--site`.

Existing files in `~/.config/tilr` and `~/tilr` are not moved automatically.
To keep an old setup, copy its config.yml into the new config folder, retaining
its explicit site/apps paths, or launch with `--config "$HOME/.config/tilr"`.

### Automatic local builds

Run `./release.command` without input. It reuses signing settings already saved in
`release.local.json`. Setup is one-time. The highest marketing version from Info.plist
(ignored while it is the dev placeholder `0.0.0-dev`) and local history is retained, and
`--version` is required when there is none; `--status` reports the missing version without
reserving or failing, and an explicit version initializes the first release. The highest build number is incremented. Reservations
in `build/release-auto.json` prevent failed attempts from reusing numbers. Both
architectures share one number. No previous artifacts are reused; nothing is published.
Selection happens under the release lock. Keep local history/state when moving to
another release machine: automatic numbering does not query public feeds.

Change the marketing version once with `./release.command --version 0.2.0`; it is
remembered for subsequent builds. The default channel is stable; use `--channel beta`
for beta. To resume an existing release, use explicit version/build with
`release_all.py --resume`. Successful builds print artifact paths and the publish-only
command. There are no terminal questions or final Return prompt. macOS Keychain
access prompts, if any, remain controlled by the key's existing access permissions.

### Application icon

`Resources/AppIcon.svg` is the green r favicon from the Tilr landing page
(`~/design/landings/tilr/index.html`). `Resources/AppIcon.icns` contains standard
and Retina sizes and is copied into Resources by both run.sh and release.py,
before signing. Info.plist declares CFBundleIconFile=AppIcon. To regenerate:

```sh
swift scripts/make_icon.swift /tmp/Tilr.iconset Resources/AppIcon.icns
```

The icon ships in the app bundle, so a normal Sparkle update also installs it.

### Update choice policy

New feeds use generate_appcast --critical-update-version with an empty value.
Sparkle marks these updates critical for all installed versions; its standard UI
hides both Skip This Version and Remind Me Later. Closing the update window still
dismisses this prompt without recording the version as skipped. Installation still
requires consent; this does not enable silent/forced installation. Sparkle may present
critical updates sooner and label them important. Previously published feeds are not
rewritten by resume; this policy applies to newly generated feeds.

### CDN verification and negative caching

Cloudflare can cache a pre-upload 404 for a DMG URL for 180 seconds. The publisher
checks existence using a unique query key, uploads if missing, and then verifies
the canonical download URL and SHA-256 before updating the feed. Canonical 404s
are retried for up to 200 seconds to cover caches from earlier attempts. A checksum
mismatch still fails immediately. Retry the same publish-only command after a failed
publication; do not rebuild or change immutable DMGs to work around a cached 404.

### Native update reminders

`AppUpdates` is a separate Swift library target/product in this package. The host
retains `AppUpdates(updaterDelegate:)`, calls `start()` after opening its window,
and uses its `controller` for Check for Updates and About. A host with its own
UNUserNotificationCenter delegate must forward update notification callbacks.
Feed URL and public key still come from the signed host bundle.

Sparkle checks every hour while the app is running (`SUScheduledCheckInterval` in
Info.plist, in seconds; Sparkle enforces a one-hour minimum). It uses the last
check time when scheduling after launch and respects saved user preferences.

Scheduled updates show a native macOS banner and a persistent Dock arrow. Clicking
the banner or Check for Updates opens Sparkle's install dialog. Permission denial
uses Sparkle's normal presentation; notification submission errors also open it.
Manual checks keep the normal UI. Reminders are cleared when the update receives
attention or its session ends. macOS controls banner appearance and Focus filtering.
Downloads/installation remain governed by Sparkle's preferences and user consent.
Development builds, `--probe` and `--no-updates` never start this module.

Acceptance on two signed builds: allow notifications, let a scheduled check find
the newer build, verify banner and Dock arrow, click and install/relaunch; repeat
with notifications denied and with a manual check. Opening About only requests
version information and must not post a banner. Verify dismissal clears reminders.
