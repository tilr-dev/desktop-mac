# Production releases through CI

Releases run through GitHub Actions. Development builds and tests use `run.sh`.
The build job produces Apple Silicon (`arm64`) and Intel (`x86_64`) DMGs; the
publication job uploads those exact signed and notarized files without rebuilding.

## Release from CI

The `Release` workflow (`.github/workflows/release.yml`) runs automatically on
pushes to `release/X.Y` and stable tags `vX.Y.Z`. Push a fix to the release branch
to get the next candidate. Pushes to `main`, other branches and RC tags do not
start this workflow; there is no manual workflow dispatch or metadata input.
Configure both `apple-signing` and `release` environments to accept `release/*`
branches and `v*` tags without required reviewers.

The pinned reusable `tilr-dev/.github` release workflow selects the next patch
version on that release line and creates `vX.Y.Z-rc.N` and a GitHub prerelease.
Each new candidate increments `N`; reruns reuse the candidate for the same commit.
Its outputs are `tag`, `version` (tag without `v`) and string `is_rc`. An empty tag
skips building and publication. Marketing version and DMG filenames use numeric
`X.Y.Z`, stripping `v` and the RC suffix from the verified tag. There is no
repository version file or generated changelog; release history is maintained in
GitHub Release notes. The source `Info.plist` remains a development template.

Dan approves stable by running `bin/release desktop-mac` in the workflow tools,
which pushes `vX.Y.Z`. The shared workflow rejects a tag whose commit does not
belong to the matching `release/X.Y` branch before creating or reusing its regular
GitHub Release. A nonempty shared tag/version and `is_rc=false` on a tag push
select stable. Both app and publish jobs check out that exact tag and verify its
commit against checkout HEAD. Both architectures are rebuilt, signed and notarized
from the tag; generated GitHub Release notes are retained.

Build is the highest published build across both architectures and both channels
plus one (stable: `https://cdn.tilr.dev/mac/<arch>/appcast.xml`, beta:
`https://cdn.tilr.dev/mac/beta/<arch>/appcast.xml`). One number is logged and used for
both architectures and publication. Missing feeds count as empty; other
HTTP/network errors and malformed feeds stop the run. Runs are serialized across
release branches with `cancel-in-progress: false` so appcast build allocation
cannot race. The latest push replaces a pending run; multiple pushes arriving
faster than an RC build are not supported. No local build history or reservations
are used.

Nothing pins the bundled tilrd: each release bundles the latest stable tilrd release
at build time, whose protocol must equal `TilrServerProtocolVersion` in `Info.plist`.

1. `app`: `fetch_server.py` acquires both architectures from the latest stable
   tilrd GitHub Release, verifies archive SHA-256, architecture, expected Developer ID
   signature and upstream version. Missing or invalid assets stop the release (fetch_server.py exits 1; the former
   exit 3 for an unpublished feed build is removed).
   No server compilation, stripping, signing or notarization happens here.
   Both app architectures are compiled without keys, then `release_all.py` signs,
   notarizes and packages the DMGs. No Sparkle key or Cloudflare token here.
2. `publish`: verifies that the existing release tag points to checkout HEAD,
   that its GitHub Release is a published prerelease for RC or a regular release
   for stable, and that it has no assets. `ci_release.py publish` validates both
   completed receipts, manifest-selected DMG paths and SHA-256 values, channel,
   public key and matching plugin inventories before any CDN writes. For stable it rechecks
   that the build exceeds all published stable and beta builds; beta retains verified
   partial-publication resume. It prepares both
   feeds, then uses the existing immutable publisher with appcast last and public
   feed readback. The same app artifacts go to beta for RC or stable for a pushed
   stable tag, without an approval prompt. No delta patches: the runner has no DMG history.
   The existing release body supplies Sparkle notes. After CDN publication,
   `ci_release.py github` validates both manifests again and attaches their unchanged
   DMGs. The title becomes `Tilr X.Y.Z-rc.N (<build>)` for RC or
   `Tilr X.Y.Z (<build>)` for stable; the body, tag and prerelease status remain
   unchanged. Existing stable assets or a build not newer than a stable feed stop
   before CDN uploads, feed changes or GitHub Release changes.
   Only this job has `contents: write` on `GITHUB_TOKEN`; the shared workflow uses
   a GitHub App token for candidate tags and GitHub Releases. No publication step creates or
   moves an existing tag, deletes a release, or replaces existing assets.
   If publication fails partway through, completed CDN uploads or GitHub assets
   remain published. Inspect the failure before releasing again; a new fix push
   produces a fresh candidate and build instead of overwriting published files.

`scripts/ci-apple-keychain.sh` imports the Apple keys into a temporary keychain (notarytool
profile `tilr-ci` from an App Store Connect API key) and removes it at the end of the job.
In `publish` the Sparkle key is a file, `TILR_SPARKLE_KEY_FILE`, instead of a Keychain item,
so there is no access prompt; its public half is checked against `TILR_UPDATE_PUBLIC_KEY`
(`scripts/sparkle_public_key.swift`). No deploy key is needed: tilrd and gitpm are public.

The shared workflow uses organization variable `TILR_BOT_CLIENT_ID` and organization
secret `TILR_BOT_PRIVATE_KEY` (available to this repository). Its GitHub App needs
Contents read and write permission and access to desktop-mac.
Both the workflow reference and its `workflow-sha` input are pinned to the same
immutable shared commit; update them together.

Secrets (Settings → Environments), provisioned by Dan:

| Environment | Secret | What it is |
|---|---|---|
| `apple-signing` (branches `release/*`, tags `v*`) | `APPLE_CERTIFICATE_P12_BASE64` | Developer ID Application `.p12` with its key, base64 |
| | `APPLE_CERTIFICATE_PASSWORD` | the `.p12` password |
| | `APPLE_SIGN_IDENTITY` | `Developer ID Application: Rexuni LLC (V57FF3MX26)` |
| | `APPLE_API_KEY_P8_BASE64` | App Store Connect API key (`.p8`, role Developer), base64 |
| | `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` | that key's Key ID and Issuer ID |
| `release` (no required reviewer, branches `release/*`, tags `v*`) | `SPARKLE_PRIVATE_KEY` | exported Sparkle EdDSA private key |
| | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 API token (S3) with object read and write on the bucket `tilr-cdn` |

## Bundled upstream server

`fetch_server.py` resolves the latest stable tilrd GitHub Release (release
candidates are prereleases and are skipped) and reads `PROTOCOL_VERSION` from its
released `tilr-proto` source. A protocol other than `TilrServerProtocolVersion` in
`Info.plist` stops the release: the application must be updated for the new
protocol first. The selected version and protocol are recorded in
`build/server-releases/selected.json`, so both architectures bundle the same release.

The bundled pair is only an offline starting point. Tilr installs it when no tilrd
is installed and at every launch, including the first launch after a Sparkle
update, runs the installed `tilrd update` for the Receive RC versions channel. A new
tilrd release therefore reaches users without a Tilr release, and no pin update or
bot pull request exists. PR CI does not acquire the server.

Desktop release tools do not publish server feeds or server update binaries.
Installed apps delegate server updates to `tilrd update`.

## Compact packaging and delta updates (implemented)

New application releases contain only their target architecture, including all
five Sparkle executables. `release_packaging.py` thins the copied framework before
inside-out signing and audits every Mach-O in the finished app. Public releases
are arm64 or x86_64; universal packaging is no longer an option. Release receipts
with `packaging: 1` trigger the same audit during publication and DMG verification.
Existing releases remain byte-for-byte unchanged.

Our Swift executable is stripped with `strip -x`
**before signing**. Its original is kept in each release's `symbols/` directory outside
the shipped app. An existing SwiftPM `Tilr.dSYM` is also copied there. Keep these
files for diagnostics: an unstripped executable alone does not supply source-level
debug information when the compiler did not generate it. Sparkle exports are not
stripped. Server artifacts are never stripped or re-signed when bundled into an app.
The bundled server is the latest stable tilrd release at build time,
independently of app numbers.

Each app release writes `sizes.json` with logical file bytes (excluding duplicate
symlink targets), DMG bytes and all Mach-O architectures. Server releases write their
own `sizes.json`. These measurements are not filesystem allocated-space totals.

Delta generation defaults to two previous source builds, configured by
`maximum_deltas` in `release-packaging.json`; set it to 0 for full-only updates.
The publisher uses only locally retained completed DMGs with matching architecture,
feed and public key, also referenced by the current published feed. It verifies the
original checksum and the feed's EdDSA signature before passing archives to
Sparkle. The CI runner has no retained DMG history, so CI publication uses full DMGs.
The shared publisher can use verified retained history when available.

Sparkle decides whether a useful delta can be generated; two is an upper bound,
not a promise. The full DMG remains in every new update item for first installations
and fallback. Server updates continue to download the full server binary.
No ARM/Intel or stable/beta mixing occurs. Generated patches are retained in
`deltas/`, their sizes/source versions in `delta-sizes.json`. They are verified with
`sign_update`, uploaded to immutable URLs and downloaded/checksummed before the
feed is changed. Resume also verifies publicly referenced deltas. A cached 404 on
a delta stops publication before the feed update: retry the same upload after CDN
propagation. A changed file at an existing URL is an error, never an overwrite.

The bundled server starts offline. Subsequent daemon updates run the installed
`tilrd update --channel stable|beta` command at every launch and from Local Server.

App update selection is controlled in Tilr → Update Settings → Receive RC versions.
It defaults to off (stable), persists between launches, and takes effect on the next
fresh appcast check. An automatic RC installation already prepared by Sparkle is
kept and can still be installed after disabling RC versions. Enabling the setting
selects beta for the app’s compiled architecture and for the next launch update or
Update tilrd action. The daemon channel is read from this preference when the update starts.

## Two independent update tracks, with a bundled server

- **Mac application**: existing Sparkle feeds under `/mac/<arch>/appcast.xml`.
- **Server**: the installed `tilrd update` command owns downloads and replacement.
  Local Server passes `--channel stable|beta` from Receive RC versions. Server
  versions remain independent of app versions; the app consumes no server feed.

The bundle contains an offline bootstrap server: the latest stable tilrd release
when the app was built. An app build copies that completed server artifact unchanged,
including its signature; it neither compiles the server nor changes its version.
The bundle carries no server manifest or version keys, and its version selects
nothing. A compatible installed server of any version is reused and updated by its
own `tilrd update` at launch. Protocol is the only compatibility condition: a daemon
speaking a newer protocol asks the user to update Tilr, an older one to update tilrd,
without application-side binary replacement. Installing a fresh app requires no
network connection.
No JavaScript `tilr` CLI, Node, npm or Git is shipped.

### Bundle a server in an application release

CI fetches the latest stable release and consumes the selected
completed artifacts from `build/server-releases/`; `TILR_SERVER_RELEASE_ROOT` may
point to the same downloaded artifacts on another build machine. App builds require verified upstream server artifacts, including preview apps. App releases remain two
separate architecture DMGs; universal server artifacts are not used.

The signed app records its supported server protocol, `TilrServerProtocolVersion`,
in the source Info.plist. Packaging verifies both executables and copies them unchanged.
The app uses the bundled binaries for offline installation; later updates run through
`tilrd update` and are confirmed through the shared daemon's normal reload path.
A newer installed server is not downgraded to the bundled version.

### Runtime and controls

Tilr shares one ordinary daemon with the terminal client. Discovery checks a running
server on the default socket first, `tilrd` in the user's login-shell PATH second,
and `~/.local/bin/tilrd` third. A found installation is used without copying
bundled binaries or claiming ownership. Incompatible servers are reported and
left untouched. The local WebSocket endpoint is `ws://127.0.0.1:7890`.

If no installation exists, Tilr copies both signed helpers from the bundle into
`~/.local/bin`, runs `tilr service install` for `sh.tilr.tilrd`, and records
`~/.local/bin/.tilr-app-installed`. State and token use the ordinary daemon defaults
(`~/.local/state/tilr` unless the normal environment overrides them). Credentials
come from `tilr token` over the same local socket used by terminal clients.
No private application daemon, state directory or `dev.tilr.server` service is
created. Previous private installations are not migrated; reinstall them.

`Tilr > Check for Updates…` checks the application. Local Server shows installed
and running tilrd versions; Refresh repeats the authenticated connection check.
At every launch, after the daemon is ready, Tilr runs the selected daemon's
`update --channel stable|beta` command in the background; the current credentials
stay in use, and a failure (for example offline) is shown in Local Server without an
alert. A daemon speaking a newer protocol than the app is not updated.
Update tilrd runs the same command on demand off the UI thread. Receive RC versions
selects its channel at the time of the update.
The app neither reads a server feed nor downloads or replaces an update itself.

If the command fails (including unavailable CDN or beta pointer), the app reports
its output, preserves credentials and leaves Update tilrd available for retry.
After success it checks actual installed and running versions and compatibility.
`local_server.update_timeout` bounds the daemon update command;
command/startup timeouts still govern local connection and readiness checks.
The `.tilr-app-pending.json` journal remains only for first installation of the
bundled daemon/client pair. Old update journals are retired without publishing
staged binaries. Closing Tilr leaves terminal sessions running.

### Removal

`local_server.enabled: false` disables application integration and leaves the
shared daemon running. Remove Local Server is available only for a daemon whose
path matches the application installation marker. It delegates startup removal
to `tilr service uninstall`, removes the installed pair and marker, and preserves
default daemon state, token and logs. The ordinary service command leaves the
running daemon and panes until it exits; launchd forgets its definition at login.
A pre-existing installation is left untouched.

The server plugin receives credentials only through its trusted top-level
`tilr://` bridge; remote profiles/defaults are preserved. External site folders
still need their rebuilt server plugin. Probe and custom-config instances never
manage the production service.

### Verification

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
swiftc -module-cache-path .build/ModuleCache Sources/Tilr/ServerInstallation.swift scripts/test_server_installation.swift -o /tmp/tilrd-installation-tests
/tmp/tilrd-installation-tests
```

Before public handoff, test first install, a server-only upgrade with an open
shell, an app-only Sparkle upgrade retaining the newer server, and offline launch
on both architectures. Check pane/shell PID survival and actual running versions.
Compilation and simulated launchd unit checks do not establish GUI/Sparkle behavior.


## Verify CI artifacts locally

Download the completed release directories from the CI artifacts. On Apple Silicon:

```sh
python3 scripts/verify_release.py build/releases/0.1.0-1-arm64 --launch
```

For Intel artifact checks (possible on the build Mac):

```sh
python3 scripts/verify_release.py build/releases/0.1.0-1-x86_64
```

The verifier checks the archive hash, DMG integrity/signature/stapling, mounts it
read-only, and verifies the app inside it: signature, stapling, Gatekeeper assessment,
version, architecture, runtime-feed-selection marker and public key (or the matching
feed for completed legacy artifacts). It always detaches the image after checks.
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

## Native plugins

WebKit and audio plugins are built from this repository's `native-plugins` directory.
`run.sh` and `release.py` place bootstrap packages in `Contents/PlugIns`; release
packaging signs them with the application's Developer ID and includes them in
notarization. `release.py --native-plugins DIR` accepts existing signed packages for
the selected architecture and checks that their publisher matches the application.

User-installed versions live outside the app in `native_plugins.directory`
(default `<config>/native-plugins`). `active.json` selects an immutable version,
which takes precedence over bootstrap packages and survives app updates. Native
module changes take effect after restarting Tilr; Cordis plugins still reload live.
See the [native plugin README](native-plugins/README.md) for build, installation,
rollback and ABI constraints. `python3 scripts/test_native_plugins.py` verifies
packages; `--gui` adds interactive checks. `tilr ctl native-plugins` reports loaded
versions and errors.

CI builds native packages for both architectures. `release.json` records each
package's ID, version, ABI and SHA-256. The CI publisher checks this inventory
against the completed app before publishing its existing DMG; differing versions
or ABIs between ARM and Intel stop publication. Plugin versions in
`native-plugins/manifests/*.json` are independent of the app version.

About reports loaded versions, external publishers and errors. Native Plugin
Settings opens the instance config. `native_plugins.allow_third_party: true`
permits external and ad-hoc packages after restart. This defaults to false.
`Tilr.entitlements` permits other publishers at the hardened runtime level;
the loader enforces the setting. Third-party code receives Tilr's process rights,
while signature integrity and ABI compatibility remain checked. Built-in release
packages are signed by the app publisher and included in notarization.
