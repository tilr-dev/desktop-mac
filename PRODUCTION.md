# Production release: set up → build → test → publish

The default process separates building from publishing. The files tested locally
are the exact signed, notarized DMGs later uploaded; publishing never rebuilds them.
There are two downloads: Apple Silicon (`arm64`) and Intel (`x86_64`).

## Быстрый рабочий процесс

Обычные команды запускайте из Terminal на релизном Mac:

```sh
cd /Users/dan/projects/tilr/tilr-mac
./release.command --status
./release.command
# Проверить собранные артефакты, затем:
./upload.command
```

- `--status` ничего не собирает, не резервирует build и не обращается к Keychain.
  Показывает значения исходного `Info.plist`, текущую релизную версию, наибольший
  локальный/зарезервированный build, следующий build, последнюю успешно собранную
  пару DMG и закреплённую версию сервера. Это **локальная история**, а не проверка
  установленного приложения или актуального CDN. Версию установленного приложения
  смотрите в About Tilr; сервер — в Tilr → Local Server….
- `release.command` собирает текущие исходники приложения. Маркетинговую версию
  сохраняет, build увеличивает. После проверки доступа резервирует номер, собирает
  отсутствующие артефакты закреплённого сервера, затем обе подписанные и
  нотарифицированные DMG. Уже собранный сервер использует без пересборки.
  Ничего не публикует. Незавершённые артефакты не перезаписывает.
- `upload.command` публикует **приложение** из последней успешно завершённой пары,
  записанной в `build/latest-app-release.json`. Не компилирует и не меняет файлы.
  Использует сохранённый канал stable/beta; печатает выбранные version/build/channel
  и после проверки CDN — две ссылки. Если новой записи ещё нет, используйте явные
  version/build. Неудачная следующая сборка не меняет указатель: перед upload
  проверьте `--status`, чтобы не выбрать предыдущую успешную сборку.

### Версия, build и канал

```sh
./release.command --version 0.3.0           # новая версия, следующий build
./release.command --build 20               # текущая версия, вручную build 20
./release.command --version 0.3.0 --build 21
./release.command --channel beta            # отдельная beta-сборка
./upload.command                            # канал последней готовой сборки
./upload.command --version 0.3.0 --build 21 --channel stable
```

Числа здесь — примеры. Явный build должен быть больше всех известных локальных
номеров, включая неудачные попытки и preview. Build не сбрасывается при смене
версии. Новая версия запоминается при резервировании сборки. `Info.plist` исходников
не переписывается: нужные номера подставляются в собранное приложение.
Проверьте номера на CDN при переносе на другой Mac: автоматическая нумерация
не читает публичные feeds. Сохраняйте каталог `build` с историей и артефактами.

После сбоя новый запуск `release.command` возьмёт следующий номер. Чтобы повторить
именно старый, используйте `release_all.py --version … --build … --resume`:
он повторно использует только завершённые проверенные артефакты. Незавершённый
каталог сначала изучите и переместите в архив. После сбоя upload повторите ту же
явную команду upload; не пересобирайте уже опубликованные файлы с тем же номером.

### Independent server release

The server has its own version/build. `server-release.json` selects the signed
upstream tilrd release for the DMG. Assign a new feed build when changing bytes;
never replace the contents of an already published build.

```sh
python3 scripts/release_server.py --version 0.2.1 --build 4 --protocol-version 1
# Inspect/test both imported artifacts, then publish the server feed:
python3 scripts/release_server.py --version 0.2.1 --build 4 --publish-only
```

Use `--channel beta` for beta feed publication. Local app publication does not
publish the server feed. Update version/build/protocolVersion in `server-release.json`
to include a new server in subsequent DMGs. Installed apps receive compatible
servers through Check for Server Updates without a new DMG.

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

The `Release` workflow (`.github/workflows/release.yml`) does the same on GitHub-hosted macOS,
without the release Mac. Run it by hand from a release branch `release/X.Y` (it fixes the set
of features; `main` moves with every merge and is never released): Actions → Release → Run
workflow with that branch, or
`gh workflow run release.yml --ref release/0.3 -f version=0.3.0 -f channel=stable`.
From any other ref (`main`, a task branch, a tag) the first job, `branch`, fails before any
job with keys starts; the `apple-signing` and `release` environments accept only `release/*`
as well.
Leave `build` empty to select the highest build in both architecture appcasts of that
channel plus one (stable: `https://cdn.tilr.dev/mac/<arch>/appcast.xml`, beta:
`https://cdn.tilr.dev/mac/beta/<arch>/appcast.xml`). One number is logged and used for
both architectures and publication. To override it, add `-f build=21`; an explicit
build must exceed every published build on that channel. Missing feeds count as empty;
other HTTP/network errors and malformed feeds stop the run. Local release numbering
and reservations are unchanged.

The pinned server is tilrd **0.2.1, build 4, protocol 1**. For its first CI release, set
`server_min_app_build=17` (Actions input, or `-f server_min_app_build=17` with `gh workflow run`).
This sets the server feed's minimum app build; the app must also support protocol 1.

1. `app`: `fetch_server.py` acquires both architectures from the exact pinned
   tilrd GitHub Release, verifies archive SHA-256, architecture, expected Developer ID
   signature and upstream version. Missing or invalid assets stop the release (fetch_server.py exits 1; the former
   exit 3 for an unpublished feed build is removed).
   No server compilation, stripping, signing or notarization happens here.
   Both app architectures are compiled without keys, then `release_all.py` signs,
   notarizes and packages the DMGs. No Sparkle key or Cloudflare token here.
2. `publish`: waits for approval in the `release` environment, then `release_server.py
   --publish-only` and `release_all.py --publish-only` publish the same artifacts. No delta
   patches: the runner has no DMG history, so the full DMG is published. After the CDN
   upload succeeds, it creates tag `v<version>` on the workflow commit (`github.sha`)
   and GitHub Release `Tilr <version> (<build>)`, attaching both unchanged DMGs from
   the `app` artifact and using `notes` for the release body as well as Sparkle.
   Only this job has `contents: write`; no commit is made to any branch. An existing tag
   causes a clear failure without updating/deleting it or changing a GitHub Release.
   If GitHub publication fails after CDN upload or tag creation, those completed
   steps remain published; inspect the failure before releasing again.

`scripts/ci-apple-keychain.sh` imports the Apple keys into a temporary keychain (notarytool
profile `tilr-ci` from an App Store Connect API key) and removes it at the end of the job.
In `publish` the Sparkle key is a file, `TILR_SPARKLE_KEY_FILE`, instead of a Keychain item,
so there is no access prompt; its public half is checked against `TILR_UPDATE_PUBLIC_KEY`
(`scripts/sparkle_public_key.swift`). No deploy key is needed: tilrd and gitpm are public.

Secrets (Settings → Environments), provisioned by Dan:

| Environment | Secret | What it is |
|---|---|---|
| `apple-signing` (branches `release/*` only) | `APPLE_CERTIFICATE_P12_BASE64` | Developer ID Application `.p12` with its key, base64 |
| | `APPLE_CERTIFICATE_PASSWORD` | the `.p12` password |
| | `APPLE_SIGN_IDENTITY` | `Developer ID Application: Rexuni LLC (V57FF3MX26)` |
| | `APPLE_API_KEY_P8_BASE64` | App Store Connect API key (`.p8`, role Developer), base64 |
| | `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` | that key's Key ID and Issuer ID |
| `release` (required reviewer Dan, `release/*` only) | `SPARKLE_PRIVATE_KEY` | contents of `generate_keys --account tilr-rexuni -x FILE` |
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

The bundled server starts offline without its public feed; to expose its independent
update, publish the completed server separately, on the desired server channel:

```sh
python3 scripts/release_server.py --version 0.1.0 --build 2 --channel beta --publish-only
```

App update selection is controlled in Tilr → Update Settings → Receive RC versions.
It defaults to off (stable), persists between launches, and takes effect on the next
fresh appcast check. An automatic RC installation already prepared by Sparkle is
kept and can still be installed after disabling RC versions. Enabling the setting
selects beta for the app’s compiled architecture. This does not
change server update settings; testing server beta uses `local_server.update_channel: beta`.

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
- **Server**: signed JSON feeds under `/server/macos/<arch>/<stable|beta>.json`.
  The app downloads and installs server updates itself; Sparkle does not install
  the server. Server version/build numbers are independent of app version/build.

The bundle contains an offline bootstrap server, pinned in `server-release.json`.
An app build copies that exact completed server artifact unchanged, including its
signature and manifest; it neither compiles the server nor changes its version.
A newer compatible installed server wins over an older bundle. Incompatible
protocols/app-build ranges and reused server numbers with changed contents fail
without stopping or downgrading the installed server. Installing a fresh app
therefore never requires a network connection; checking for updates is optional.
No JavaScript `tilr` CLI, Node, npm or Git is shipped.

### Acquire and publish a server independently

The server must already be signed and notarized in the tilr-dev/tilrd GitHub Release.
The desktop tools download `tilr-v<version>-<target>.tar.gz` and its `.sha256` file,
verify the archive before reading executable bytes, then check architecture and the
Developer ID Application signature, team V57FF3MX26, and secure timestamp.
The exact upstream version is `X.Y.Z-<commit>`; the desktop feed build is not part
of the binary version. The signed clap version/platform string is inspected for
both architectures; the native executable's `--version` is checked as well.

```sh
python3 scripts/release_server_all.py --version 0.2.1 --build 4 --min-app-build 17 --protocol-version 1
# Show the plan without credentials, downloads or publication:
python3 scripts/release_server_all.py --version 0.2.1 --build 4 --min-app-build 17 --protocol-version 1 --preview
```

The command checks publication access without Apple credentials, acquires both
architectures and shows both completion receipts. Type exactly `publish` after
inspection to publish the server feeds. Refusal or EOF leaves artifacts available.
After publication, both signed feeds are checked and the JSON app pin is printed.
No source checkout or Rust/Zig/protoc installation is required. Import needs the
public update key; publication additionally needs the existing feed/CDN credentials.

Lower-level commands:

```sh
python3 scripts/release_server.py --version 0.2.1 --build 4 --protocol-version 1 --min-app-build 17
python3 scripts/release_server.py --version 0.2.1 --build 4 --publish-only
```

`--arch arm64` or `--arch x86_64` selects one architecture; default is both.
`--channel beta` selects the server beta feed independently of the app channel.
`--min-app-build` / `--max-app-build` constrain app compatibility. Supply the
protocol declared by the selected upstream release with `--protocol-version`.
Output is `build/server-releases/<version>-<build>-<arch>`. Existing directories
are never overwritten; inspect and move aside incomplete output before retrying.

The upstream server and client executables are already Developer ID signed and notarized;
acquisition verifies both signatures, matching versions and archive checksum before writing the completion receipt. Publication checks the receipt/checksum, preserves immutable
binary URLs, verifies the public download, then publishes the signed feed last.
It retains previous compatible releases instead of making older clients download
an incompatible latest server. Feed signatures use Ed25519 (CryptoKit at runtime),
with the existing release key initially shared with the app. The build-time
`sign_update` utility only signs bytes; the server updater is not a Sparkle updater.
All feeds are signed with explicit component/architecture/channel metadata.
Publish from one release runner: the local lock does not serialize different Macs,
and publishing the two architecture feeds is not atomic. A failed public check
requires retrying the same `--publish-only`, not replacing a binary at its URL.
No app DMG or Sparkle feed is published by this command.

### Bundle a server in an application release

Set `server-release.json` to the desired **server** version, build and protocol.
Run the existing application release command below. It consumes the corresponding
completed artifacts from `build/server-releases/`; `TILR_SERVER_RELEASE_ROOT` may
point to the same downloaded artifacts on another build machine. App builds require verified upstream server artifacts, including preview apps. App releases remain two
separate architecture DMGs; universal server artifacts are not used.

The app records its supported server protocol, bundled server identity, server
feed base URL and public verification key in its signed Info.plist. Downloads
are selected by server build within the supported protocol, architecture and app
build range; hashes/signatures are verified before replacement. The app installs
the replacement binary and requests reload; tilrd checks reload-state compatibility
before handing over. The app confirms the update through `tilr version` on the default socket.
If reload is refused and the running version stays unchanged, the app reports
"The local server did not become ready. Reload did not complete: running version
X, expected Y" with the server log path and confirmation that existing processes
were not stopped. The supervisor and terminals keep running, and the replacement
binary remains installed. To use that binary after a refused reload, stop the
service, then start it again; this ends the existing terminal sessions.
The next application build can still bundle an older compatible server; it will
not undo an independent server update.

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

`Tilr > Check for Updates…` checks the application; `Check for Server Updates…`
checks the independent server feed and requires explicit Update Server approval.
Local Server shows the actual running version using the ordinary CLI's authenticated
socket connection. Refresh repeats that check. Existing installations without app
feed receipts are offered only releases with a newer upstream semantic version;
commit suffixes alone do not establish release order.
Feed errors leave the daemon and credentials usable. A feed HTTP error means
"No server release is published for <channel>/<arch>"; a binary HTTP error is
"Server update download failed (HTTP <status>)". Settings for automatic checks,
channel, intervals, network timeouts and size limits remain in `default.yml`.

Explicit updates replace the discovered executable atomically and request
session-preserving reload. `tilrd.previous` stays next to that executable; app
receipts and the pending transaction are `.tilr-app-server.json`,
`.tilr-app-server.previous.json` and `.tilr-app-pending.json` in `~/.local/bin`.
They do not prevent ordinary `tilr update`. If the running executable cannot be
resolved, replacement is refused. Failed reloads keep the new installed binary,
the previous copy and a pending transaction for recovery on the next launch;
they never stop a live supervisor or report readiness before the expected version.
Closing Tilr leaves terminal sessions running.

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
swiftc -module-cache-path .build/ModuleCache Sources/Tilr/ServerInstallation.swift Sources/Tilr/ServerUpdates.swift scripts/test_server_updates.swift -o /tmp/tilrd-update-tests
/tmp/tilrd-update-tests
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
python3 scripts/release_all.py --check --publish-only
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

`--channel stable|beta` selects publication routing in `release.json`; it is absent
from the signed application’s Info.plist. Stable and beta builds with the same
architecture/version/build/key have identical Info.plist bytes. The same tested DMG
can therefore be published on either channel without changing the bundle. The
current upload commands still validate their receipt’s publication channel; this
change does not add a promotion command.

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
architectures share one number. Application artifacts are always rebuilt; completed pinned server artifacts are reused unchanged. Nothing is published.
Selection happens under the release lock. `--build N` can reserve an explicit higher number; `--status` only shows local history without reserving anything. Keep local history/state when moving to
another release machine: automatic numbering does not query public feeds.

Change the marketing version once with `./release.command --version 0.2.0`; it is
remembered for subsequent builds. The default channel is stable; use `--channel beta`
for beta. To resume an existing release, use explicit version/build with
`release_all.py --resume`. Successful builds print artifact paths and the publish-only
command. There are no terminal questions or final Return prompt. macOS Keychain
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
