# Production release: set up → build → test → publish

The default process separates building from publishing. The files tested locally
are the exact signed, notarized DMGs later uploaded; publishing never rebuilds them.
There are two downloads: Apple Silicon (`arm64`) and Intel (`x86_64`).

## 1. Set up the release Mac once

Use a normal Terminal on the Mac holding the Rexuni Developer ID private key:

```sh
cd /Users/dan/projects/tilr/apps/mac
./setup-release.command
```

This script asks for the existing Developer ID Application identity, resolves the
pinned Swift dependencies, creates/reuses the Sparkle signing key in Keychain and
configures Apple notarization. Enter an app-specific Apple password only at Apple's
Terminal prompt. It saves non-secret identity/profile/public-key settings in ignored
`release.local.json`. It builds no application and uploads no release.

Requirements: macOS 14+, Xcode, Python 3.11+, access to the Rexuni certificate AND
private key, the notarization service, and `hdiutil`. The app-specific password can
be created at account.apple.com → Sign-In and Security → App-Specific Passwords.
The Rexuni Team ID is the code in the certificate's name. Do not create/revoke the
existing certificate because an agent sandbox cannot see it.

Publication access is configured separately. With Node >=22 and Wrangler installed:

```sh
wrangler login
python3 scripts/release_all.py --check --publish-only
```

That check uses the existing Sparkle key and Cloudflare account's `tilr-cdn` bucket.
It needs no Apple signing private key or notarization login, and does not compile or
create disk images. Publishing still needs macOS signature/stapling verification,
Sparkle tools and disk-image mounting when generating the appcast. An automated
publisher may use an authorized Cloudflare token from its secret store instead of
interactive login.

For this development Mac, if `node --version` selects old Node 18, use
`export PATH="/opt/homebrew/bin:$PATH"` in this Terminal; the Homebrew Node is newer.
For agent execution, provision these same accesses for the actual agent process or
an explicitly configured macOS release runner. Scripts cannot grant OS/tool
permissions. See [AGENT_RELEASE.md](AGENT_RELEASE.md).

## 2. Build both production DMGs, without publishing

```sh
python3 scripts/release_all.py --version 0.1.0 --build 1 --channel stable
```

Or open `release.command` for an automatic build. It also never publishes. The command
builds both architectures, signs them with Developer ID, notarizes/staples them,
and creates each DMG. Apple receives the binaries for notarization; nothing is
uploaded to the public Tilr CDN and existing update feeds remain unchanged.

Artifacts:

```text
build/releases/0.1.0-1-arm64/Tilr-0.1.0-1-arm64.dmg
build/releases/0.1.0-1-x86_64/Tilr-0.1.0-1-x86_64.dmg
```

Keep each entire release directory: the publisher also needs `Tilr.app` and the
`release.json` completion receipt, including the DMG SHA-256. Preserve these artifacts
if the source changes after building. Changed source does not change what will be
published. Do not edit the signed app or DMG.

Choose `stable` at build time when these exact files will become the production
release. The feed URL is embedded inside the signed application. A beta-built app
cannot be promoted to stable by moving its DMG: that requires a new build and test.

## 3. Test the exact artifacts locally

On Apple Silicon:

```sh
python3 scripts/verify_release.py build/releases/0.1.0-1-arm64 --launch
```

For Intel artifact checks (possible on the build Mac):

```sh
python3 scripts/verify_release.py build/releases/0.1.0-1-x86_64
```

The verifier checks the archive hash, DMG integrity/signature/stapling, mounts it
read-only, and verifies the app inside it: signature, stapling, Gatekeeper assessment,
version, architecture, feed and public key. It always detaches the image after checks.
`verification.json` records artifact checks, **not a GUI test pass**.

`--launch` copies the app out of the verified DMG to `build/local-tests/`, then launches
a separate instance with its own config, PID/socket and web storage. `--no-updates`
disables Sparkle for that test instance. It does not replace /Applications/Tilr.app
or restart the user's normal Tilr. Verify the welcome page, window controls and
external HTML/CSS/JS site loading manually. Close the test window when finished.

For Intel runtime testing, copy the release directory to an actual Intel Mac and
run the verifier there with `--launch`, or install that DMG manually. Compilation
and archive verification on Apple Silicon do not prove Intel runtime behavior.
Also test installation through Finder from a browser-downloaded DMG on a clean
Mac/account, because a locally built file may not have browser quarantine metadata.

Stable-feed apps can be tested locally before their release is public: the isolated
launch disables update checks. A true Sparkle N→N+1 test needs two notarized releases
on the separate beta feeds, a matching Mac and real installation/relaunch. Do not
claim this passed merely because the verifier or script unit tests passed.

## 4. Publish those same files later

After local testing:

```sh
python3 scripts/release_all.py --version 0.1.0 --build 1 --channel stable --publish-only
```

This command refuses a missing/incomplete architecture. It never calls Swift,
never resolves source dependencies, never signs with the Apple key, and never
submits a new notarization request. It verifies existing notarization/signatures,
generates/verifies Sparkle signatures, uploads the exact DMG bytes and checks the
public download before changing a feed. Add `--notes /absolute/path/changes.txt`
to include release notes without modifying the DMGs.

It prepares both appcasts before publishing either. Two feed writes are not atomic:
if one succeeds and the other fails, repeat the SAME `--publish-only` command.
An already-published matching archive is verified and retained; it is not overwritten.
A newer build or different content at an existing URL stops the process.

On success, the two website download URLs are printed and saved in
`build/releases/0.1.0-1-stable-downloads.json`. The website's Apple Silicon and Intel
buttons can use these URLs. The scripts do not edit or deploy the website itself.

Next release: increase build (for example `0.1.1`, build `2`) and repeat build → test
→ publish-only. For a bad published release, fix/revert the source and use a HIGHER
build number. Keep the same bundle ID, feed URLs and normal signing keys.

## Current setup status

On 2026-10-11, release.local.json is configured and local release receipts record
publication of 0.2.0 build 4 for both arm64 and x86_64. These files are ignored local
state. Restricted agent execution still cannot access the signing keys; use the
configured release Mac's normal Terminal. Recorded publication does not establish
Intel runtime behavior or prove a complete Sparkle install/relaunch test.

### Automatic local builds

Run `./release.command` without input. It reuses signing settings already saved in
`release.local.json`. Setup is one-time. The highest marketing version from Info.plist
and local history is retained; the highest build number is incremented. Reservations
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
