# Production release: set up → build → test → publish

The default process separates building from publishing. The files tested locally
are the exact signed, notarized DMGs later uploaded; publishing never rebuilds them.
There are two downloads: Apple Silicon (`arm64`) and Intel (`x86_64`).

## Local beta build and publication

Run local beta commands from Terminal on the release Mac:

```sh
cd /Users/dan/projects/tilr/tilr-mac
./release.command --status
./release.command --channel beta
# Inspect and test the completed artifacts, then:
./upload.command
```

- `--status` shows the source version, remembered version, highest local/reserved
  build, next build, last completed DMG pair and pinned server. It does not build,
  reserve numbers, access Keychain or query the CDN. Check installed versions in
  About Tilr and Tilr → Local Server….
- `release.command` builds current app sources, retaining the marketing version and
  increasing the build after credential preflight. It acquires missing pinned signed
  server artifacts, reuses completed servers unchanged, and creates both signed and
  notarized DMGs. It publishes nothing and never overwrites incomplete output.
- `upload.command` publishes the last completed app pair recorded in
  `build/latest-app-release.json` without rebuilding or changing files. It prints
  version/build/channel and the verified CDN URLs. A saved stable channel is refused:
  stable requires promotion of a verified CI RC. There is no direct stable override.
  Without a saved pair, provide explicit version/build/channel. A failed later build
  leaves the pointer unchanged; inspect `--status` before uploading.

### Version, build and channel

```sh
./release.command --version 0.3.0 --channel beta  # new version, next local build
./release.command --build 20 --channel beta       # explicit local build
./release.command --version 0.3.0 --build 21 --channel beta
./upload.command                                 # saved completed pair
./upload.command --version 0.3.0 --build 21 --channel beta
```

These numbers are examples. An explicit local build must exceed all local numbers,
including failed and preview reservations; changing version never resets it. The
version is remembered when reserving a build, and source Info.plist is unchanged.
Check CDN builds when moving to another Mac: local numbering does not read public
feeds. Keep the build directory with its history and artifacts.

After failure, the next build reserves a new number. To reuse the exact old completed
artifacts, pass explicit version/build/channel and `--resume` to release_all.py.
Inspect and archive incomplete output first. After an upload failure, repeat the
same explicit upload command; never rebuild published bytes under the same number.

### Pinned upstream server

`server-release.json` selects the signed upstream tilrd version, artifact revision
(`build`) and protocol for the DMG. The revision identifies local completed artifacts;
it is not a published server feed number. Update the pin to bundle a different release.

```sh
python3 scripts/release_server.py --version 0.2.1 --build 4 --protocol-version 1
```

Desktop release tools do not publish server feeds or server update binaries.
Installed apps delegate server updates to `tilrd update`.

### Проверка и ограничения доступа

После сборки выполните команды из раздела 3 для **выведенных каталогов**, проверьте
запуск приложения и состояние Local Server. Полный тест обновления требует
реальной установки/Sparkle и проверки сохранения терминальных сессий. Затем upload.
`upload.command` проверяет артефакты и публикацию, но не заменяет ручную проверку UI.

При `Developer ID identity is unavailable` используйте обычный Terminal релизного
Mac с существующим сертификатом и приватным ключом. Не создавайте новый ключ из-за
ограничений агента. `release.command` и `upload.command` добавляют Homebrew в PATH.
One-time setup: `setup-release.command`; CDN access: R2 keys for the AWS CLI (section 1).
Процесс сборки не останавливает development-сервер. Если он занимает порт 7890,
остановите именно его в терминале запуска (Ctrl+C) перед запуском новой версии.

При `A timestamp was expected but was not found` ошибка возникает при получении
обязательной secure timestamp у Apple, уже после компиляции. `release.py` повторяет
подпись того же файла до трёх попыток с паузой 5 секунд. Это также применяется к
Sparkle, серверному бинарнику и проверке подписи в preflight. Число попыток и пауза
заданы в `release-packaging.json`: `codesign_attempts`, `codesign_retry_delay_seconds`.
Ошибки сертификата/Keychain не повторяются; `--timestamp` остаётся обязательным.
Если все попытки исчерпаны, проверьте доступ к `timestamp.apple.com` из релизного
процесса и повторите сборку через описанный выше `--resume`, сохранив завершённую
архитектуру и переместив незавершённый каталог в архив.

## Release from CI

The `Release` workflow (`.github/workflows/release.yml`) runs automatically on each
push to `release/X.Y`. Push a fix to the release branch to get the next candidate;
there is no manual workflow dispatch or version, build, channel or RC input.
Pushes to `main`, other branches and tags do not start this workflow. The shared
workflow validates canonical `release/X.Y` names before obtaining its App token.
Both `apple-signing` and `release` environments accept only `release/*` branches
and have no required reviewers.

The pinned reusable `tilr-dev/.github` release workflow opens or updates the
release-please PR, chooses `X.Y.Z` for that release line and creates
`vX.Y.Z-rc.N` and a GitHub prerelease. Each new push increments `N`; reruns reuse
the candidate for the same commit. `release-please-config.json`,
`.release-please-manifest.json` and `version.txt` track the release version without
changing the source `Info.plist` template. The app marketing version and DMG
filenames remain numeric `X.Y.Z` without `-rc`.

Merging the release PR is the only release approval: the shared workflow creates
stable tag `vX.Y.Z` without an environment approval. That run skips candidate
building and beta publication. Stable builds and publication from the tag are a
separate workflow change; this workflow publishes candidates only.

Build is the highest published build across both architectures and both channels
plus one (stable: `https://cdn.tilr.dev/mac/<arch>/appcast.xml`, beta:
`https://cdn.tilr.dev/mac/beta/<arch>/appcast.xml`). One number is logged and used for
both architectures and publication. Missing feeds count as empty; other
HTTP/network errors and malformed feeds stop the run. Runs use `queue: max` and are serialized across
release branches so pending pushes are retained (up to GitHub's 100-run limit)
and appcast build allocation cannot race. Local release numbering
and reservations are unchanged.

The pinned server is tilrd **0.2.1, artifact revision 4, protocol 1**.

1. `app`: `fetch_server.py` acquires both architectures from the exact pinned
   tilrd GitHub Release, verifies archive SHA-256, architecture, expected Developer ID
   signature and upstream version. Missing or invalid assets stop the release (fetch_server.py exits 1; the former
   exit 3 for an unpublished feed build is removed).
   No server compilation, stripping, signing or notarization happens here.
   Both app architectures are compiled without keys, then `release_all.py` signs,
   notarizes and packages the DMGs. No Sparkle key or Cloudflare token here.
2. `publish`: verifies that the existing RC tag points to the workflow commit,
   that its GitHub release is a published prerelease, and that it has no assets.
   It then uses `release_all.py --publish-only` to publish the same app artifacts to
   beta without an approval prompt. No delta patches: the runner has no DMG history.
   The existing prerelease body supplies Sparkle notes. After CDN publication,
   both unchanged DMGs are attached to that prerelease and its title becomes
   `Tilr X.Y.Z-rc.N (<build>)`; its body and tag remain unchanged.
   Only this job has `contents: write` on `GITHUB_TOKEN`; the shared workflow uses
   a GitHub App token for release PRs and tags. No publication step creates or
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
Contents, Pull requests and Issues write permissions and access to desktop-mac.
Both the workflow reference and its `workflow-sha` input are pinned to the same
immutable shared commit; update them together.

Secrets (Settings → Environments), provisioned by Dan:

| Environment | Secret | What it is |
|---|---|---|
| `apple-signing` (branches `release/*` only) | `APPLE_CERTIFICATE_P12_BASE64` | Developer ID Application `.p12` with its key, base64 |
| | `APPLE_CERTIFICATE_PASSWORD` | the `.p12` password |
| | `APPLE_SIGN_IDENTITY` | `Developer ID Application: Rexuni LLC (V57FF3MX26)` |
| | `APPLE_API_KEY_P8_BASE64` | App Store Connect API key (`.p8`, role Developer), base64 |
| | `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` | that key's Key ID and Issuer ID |
| `release` (no required reviewer, `release/*` only) | `SPARKLE_PRIVATE_KEY` | contents of `generate_keys --account tilr-rexuni -x FILE` |
| | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 API token (S3) with object read and write on the bucket `tilr-cdn` |

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
The current server pin is **0.2.1 build 4, protocol 1**, independently of app numbers.

Each app release writes `sizes.json` with logical file bytes (excluding duplicate
symlink targets), DMG bytes and all Mach-O architectures. Server releases write their
own `sizes.json`. These measurements are not filesystem allocated-space totals.

Delta generation defaults to two previous source builds, configured by
`maximum_deltas` in `release-packaging.json`; set it to 0 for full-only updates.
The publisher uses only locally retained completed DMGs with matching architecture,
feed and public key, also referenced by the current published feed. It verifies the
original checksum and the feed's EdDSA signature before passing archives to
Sparkle. Keep `build/releases/` history on the release machine. If suitable local
history is absent, publication proceeds with a full DMG, without a delta.

Sparkle decides whether a useful delta can be generated; two is an upper bound,
not a promise. The full DMG remains in every new update item for first installations
and fallback. Server updates continue to download the full server binary.
No ARM/Intel or stable/beta mixing occurs. Generated patches are retained in
`deltas/`, their sizes/source versions in `delta-sizes.json`. They are verified with
`sign_update`, uploaded to immutable URLs and downloaded/checksummed before the
feed is changed. Resume also verifies publicly referenced deltas. A cached 404 on
a delta stops publication before the feed update: retry the same upload after CDN
propagation. A changed file at an existing URL is an error, never an overwrite.

Use a new app build for the optimized release:

```sh
./release.command --status
./release.command --channel beta
# Verify/test the printed artifacts, including an actual Sparkle upgrade.
./upload.command
```

The bundled server starts offline. Subsequent daemon updates run the installed
`tilrd update --channel stable|beta` command from Local Server.

App update selection is controlled in Tilr → Update Settings → Receive RC versions.
It defaults to off (stable), persists between launches, and takes effect on the next
fresh appcast check. An automatic RC installation already prepared by Sparkle is
kept and can still be installed after disabling RC versions. Enabling the setting
selects beta for the app’s compiled architecture and for the next Update tilrd action.
The daemon channel is read from this preference when the action starts.

Verification so far: local tests cover both Sparkle architectures and ad-hoc
signatures, real BinaryDelta create/apply and the reconstructed bundle signature,
feed history isolation, rejected malformed patches, missing public patches, and
publication ordering. The actual stripped ARM server preserves its version and
state-format reporting. This does **not** establish Developer ID notarization,
Intel runtime, live CDN delta delivery, a GUI Sparkle fallback, or shell PID
survival through an optimized release. Verify those on the release/test Macs before
production handoff. Source-level changes here publish nothing automatically.

## Two independent update tracks, with a bundled server

- **Mac application**: existing Sparkle feeds under `/mac/<arch>/appcast.xml`.
- **Server**: the installed `tilrd update` command owns downloads and replacement.
  Local Server passes `--channel stable|beta` from Receive RC versions. Server
  versions remain independent of app versions; the app consumes no server feed.

The bundle contains an offline bootstrap server, pinned in `server-release.json`.
An app build copies that exact completed server artifact unchanged, including its
signature and manifest; it neither compiles the server nor changes its version.
A compatible installed server is reused. A version older than the bundle pin or
an incompatible protocol produces an Update tilrd prompt without application-side
binary replacement. Installing a fresh app requires no network connection.
No JavaScript `tilr` CLI, Node, npm or Git is shipped.

### Acquire a signed upstream server

The server and client must already be signed and notarized in the tilr-dev/tilrd
GitHub Release. Desktop tools download `tilr-v<version>-<target>.tar.gz` and its
`.sha256` file, verify the archive before extraction, then check both executables'
architecture, matching upstream version, Developer ID Application signature,
team V57FF3MX26 and secure timestamp. The exact upstream version is `X.Y.Z-<commit>`.
Both architectures' signed version/platform strings are inspected; native executables'
`--version` output is checked as well.

```sh
python3 scripts/release_server_all.py --version 0.2.1 --build 4 --protocol-version 1
# Show the plan without credentials or downloads:
python3 scripts/release_server_all.py --version 0.2.1 --build 4 --protocol-version 1 --preview
```

The wrapper acquires both architectures, verifies completed artifacts, displays
both receipts and prints a JSON application pin. It does not prompt for publication
or use Sparkle/CDN credentials. No source checkout or Rust/Zig/protoc is required.

The lower-level command accepts `--arch arm64` or `--arch x86_64` (default: both):

```sh
python3 scripts/release_server.py --version 0.2.1 --build 4 --protocol-version 1
```

Supply the protocol declared by the selected upstream release with `--protocol-version`.
The `--build` artifact revision must match the application pin. Output is
`build/server-releases/<version>-<build>-<arch>`. Existing directories are never
overwritten; inspect and move aside incomplete output before retrying.
No server feed channel, app-build range, publication or signing options are supported.

### Bundle a server in an application release

Set `server-release.json` to the desired **server** version, build and protocol.
Run the existing application release command below. It consumes the corresponding
completed artifacts from `build/server-releases/`; `TILR_SERVER_RELEASE_ROOT` may
point to the same downloaded artifacts on another build machine. App builds require verified upstream server artifacts, including preview apps. App releases remain two
separate architecture DMGs; universal server artifacts are not used.

The signed app records its supported server protocol and bundled server identity
in Info.plist. Packaging verifies both pinned executables and copies them unchanged.
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
Update tilrd runs the selected daemon's `update --channel stable|beta` command off
the UI thread. Receive RC versions selects its channel at the time of the action.
The app neither reads a server feed nor downloads or replaces an update itself.

If the command fails (including unavailable CDN or beta pointer), the app reports
its output, preserves credentials and leaves Update tilrd available for retry.
After success it checks actual installed and running versions and compatibility.
If beta selected an older RC after promotion, a version below the bundle pin keeps
the update prompt. `local_server.update_timeout` bounds the daemon update command;
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

## 1. Set up the release Mac once

Use a normal Terminal on the Mac holding the Rexuni Developer ID private key:

```sh
cd /Users/dan/projects/tilr/tilr-mac
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

Publication access is configured separately: the AWS CLI (`brew install awscli`) with an
R2 API token for the bucket (Cloudflare → R2 → Manage API tokens, Object Read & Write on
`tilr-cdn`; the same kind of keys as tilrd's CDN upload). Keep them in their own profile so
the default AWS credentials stay untouched:

```sh
aws configure --profile tilr-r2      # Access Key ID and Secret of the R2 token, region auto
export AWS_PROFILE=tilr-r2
python3 scripts/release_all.py --check --publish-only --channel beta
```

That check uses the existing Sparkle key and `aws s3api head-bucket` on `tilr-cdn` through
the R2 endpoint.
It needs no Apple signing private key or notarization login, and does not compile or
create disk images. Publishing still needs macOS signature/stapling verification,
Sparkle tools and disk-image mounting when generating the appcast. An automated
publisher takes the R2 keys as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from its
secret store.
For agent execution, provision these same accesses for the actual agent process or
an explicitly configured macOS release runner. Scripts cannot grant OS/tool
permissions. See [AGENT_RELEASE.md](AGENT_RELEASE.md).

## 2. Build both production DMGs, without publishing

```sh
python3 scripts/release_all.py --version 0.1.0 --build 1 --channel beta
```

Or run `./release.command --channel beta` for an automatic build. It also never publishes. The command
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

`--channel stable|beta` selects receipt routing in `release.json`; it is absent
from the signed application's Info.plist. Stable and beta builds with the same
architecture/version/build/key have identical Info.plist bytes. Publication with
`release_all.py --publish` or `--publish-only` is permitted only for beta; an explicit
or saved stable channel stops before CDN uploads or feed changes. No flag or
environment variable enables direct stable publication.

For production, publish a CI RC to beta, download and check that RC on a Mac (enable
Receive RC versions when testing updates), then promote those exact checked artifacts
to stable. Promotion preserves the DMG bytes, numeric marketing version and build;
it does not rebuild, re-sign or notarize them. The promotion command is a separate
workflow; the release/upload commands here do not publish stable.

The signed bundle contains the verification public key and a runtime-selection
marker, with no `SUFeedURL`. Tilr → Update Settings exposes Receive RC versions
(initially off, saved between launches), automatic checks and automatic downloads.
The next Sparkle check uses `https://cdn.tilr.dev/mac/<arch>/appcast.xml` when RC
versions are off, or `https://cdn.tilr.dev/mac/beta/<arch>/appcast.xml` when on, for
the app’s compiled `arm64` or `x86_64` architecture. Changing the setting leaves an
active check unchanged. A leftover `TILR_UPDATE_FEED` does not affect app selection.

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

## 4. Publish those same files to beta later

After local testing:

```sh
python3 scripts/release_all.py --version 0.1.0 --build 1 --channel beta --publish-only
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
`build/releases/0.1.0-1-beta-downloads.json`. The website's Apple Silicon and Intel
buttons can use these URLs. The scripts do not edit or deploy the website itself.

Next release: increase build (for example `0.1.1`, build `2`) and repeat build → test
→ publish-only, keeping `--channel beta` for both build and publication. For a bad published release, fix/revert the source and use a HIGHER
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
architectures share one number. Application artifacts are always rebuilt; completed pinned server artifacts are reused unchanged. Nothing is published.
Selection happens under the release lock. `--build N` can reserve an explicit higher number; `--status` only shows local history without reserving anything. Keep local history/state when moving to
another release machine: automatic numbering does not query public feeds.

Change the marketing version once with `./release.command --version 0.2.0`; it is
remembered for subsequent builds. The default receipt channel is stable (build-only);
use `--channel beta` for a locally publishable pair. Stable publication requires
promotion of a verified CI RC. To resume an existing release, use explicit version/build with
`release_all.py --resume`. Successful builds print artifact paths; beta builds also print the publish-only
command, while stable builds explain the CI RC promotion requirement. There are no terminal questions or final Return prompt. macOS Keychain
access prompts, if any, remain controlled by the key's existing access permissions.


## Нативные плагины

Браузер WebKit и аудио собираются из папки `native-plugins` этого репозитория.
Приложение зависит только от его SDK. `run.sh` и `release.py` кладут стартовые
пакеты в `Contents/PlugIns`; release подписывает их тем же Developer ID и включает
в нотарификацию приложения. `release.py --native-plugins DIR` принимает готовые
подписанные пакеты для нужной архитектуры. Проверяется совпадение издателя с приложением.

Установленные пользователем версии лежат вне `.app`: каталог `native_plugins.directory`
в конфигурации экземпляра (по умолчанию `<config>/native-plugins`). Указатель `active.json`
выбирает неизменяемую версию пакета. Она приоритетнее стартовой и сохраняется при обновлении
приложения. Обновление плагина не меняет `.app`; загруженный нативный модуль заменяется
при следующем запуске Tilr. Cordis-плагины по-прежнему перезагружаются на лету.

Сборка, установка, откат и ограничения ABI описаны в
[README нативных плагинов](native-plugins/README.md). Проверка:
`python3 scripts/test_native_plugins.py`; интерактивные проверки добавляет `--gui`.
Команда `tilr ctl native-plugins` показывает загруженные версии и ошибки.

`release.command` пересобирает нативные пакеты для обеих архитектур. В `release.json`
сохраняются ID, версия, ABI и SHA-256 бинарника каждого пакета. `upload.command`
показывает этот состав, проверяет его по готовому `.app` и публикует ранее собранный
DMG. Разные версии/ABI плагинов в ARM и Intel релизах останавливают публикацию.
Версии задаются в `native-plugins/manifests/*.json` независимо от версии приложения.

About показывает фактически загруженные версии, сторонних издателей и ошибки.
Tilr → Native Plugin Settings… открывает `config.yml` экземпляра. Пользователь может
добавить `native_plugins.allow_third_party: true` (в YAML-секцию `native_plugins`),
чтобы разрешить сторонние и ad-hoc пакеты. По умолчанию настройка выключена;
включение и выключение требуют перезапуска. `Tilr.entitlements` позволяет загрузку
других издателей на уровне hardened runtime; решение принимает загрузчик по настройке.
Сторонний код получает права процесса Tilr. Целостность подписи и совместимость ABI
проверяются и при включённом разрешении. Встроенные release-пакеты всё равно подписываются
издателем приложения и входят в нотарификацию.
