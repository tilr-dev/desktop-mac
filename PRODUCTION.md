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

### Отдельный серверный релиз

У сервера собственные version/build. App build 21 не означает server build 21.
`server-release.json` определяет, какой готовый сервер входит в новую DMG.
Изменение исходников сервера само по себе не меняет закреплённый артефакт:
для нового сервера назначьте новый server build и соберите его отдельно.

```sh
# Пример нового серверного релиза; номера независимы от приложения:
python3 scripts/release_server.py --version 0.1.1 --build 2
# После проверки этих артефактов:
python3 scripts/release_server.py --version 0.1.1 --build 2 --publish-only
```

Для beta добавляйте `--channel beta` при публикации сервера. Публикация приложения
не публикует серверный feed; сервер внутри DMG запускается и без него. Для первого
релиза обоих каналов отдельно опубликуйте закреплённый сервер, затем приложение.
Чтобы включить новый сервер в последующие DMG, обновите version/build/protocolVersion
в `server-release.json` и запустите `release.command`. Уже установленные приложения
получают совместимый сервер через Check for Server Updates…, без обновления DMG.

### Проверка и ограничения доступа

После сборки выполните команды из раздела 3 для **выведенных каталогов**, проверьте
запуск приложения и состояние Local Server. Полный тест обновления требует
реальной установки/Sparkle и проверки сохранения терминальных сессий. Затем upload.
`upload.command` проверяет артефакты и публикацию, но не заменяет ручную проверку UI.

При `Developer ID identity is unavailable` используйте обычный Terminal релизного
Mac с существующим сертификатом и приватным ключом. Не создавайте новый ключ из-за
ограничений агента. `release.command` и `upload.command` добавляют Homebrew в PATH.
Разовая настройка — `setup-release.command`, доступ к Cloudflare — `wrangler login`.
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

## Compact packaging and delta updates (implemented)

New application releases contain only their target architecture, including all
five Sparkle executables. `release_packaging.py` thins the copied framework before
inside-out signing and audits every Mach-O in the finished app. Public releases
are arm64 or x86_64; universal packaging is no longer an option. Release receipts
with `packaging: 1` trigger the same audit during publication and DMG verification.
Existing releases remain byte-for-byte unchanged.

Our Swift executable and newly built server executable are stripped with `strip -x`
**before signing**. Originals are kept in each release's `symbols/` directory outside
the shipped app. An existing SwiftPM `Tilr.dSYM` is also copied there. Keep these
files for diagnostics: an unstripped executable alone does not supply source-level
debug information when the compiler did not generate it. Sparkle exports are not
stripped. Server artifacts are never stripped or re-signed when bundled into an app.
The first compact server is pinned as **0.1.0 build 2**, independently of app numbers.

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

For stable app distribution build another new app build with `--channel stable`;
the channel is embedded in the signed bundle. Server beta and app beta are separate
settings: testing server beta requires `local_server.update_channel: beta`.

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

### Build and publish a server independently

For the complete tagged-source workflow, run on the signing Mac:

```sh
python3 scripts/release_server_all.py --version 0.1.0 --build 2 --min-app-build 1 --tag v0.1.0
# Inspect the plan without keys, signing, notarization or publication:
python3 scripts/release_server_all.py --version 0.1.0 --build 2 --min-app-build 1 --tag v0.1.0 --preview
```

The command uses a temporary detached worktree of the local tag in
`~/projects/tilr/git/tilrd`; override the clone with `--tilrd-repo PATH`.
It validates the tagged protocol, prepends Homebrew to PATH (Node >=22), runs
`release_all.py --check --publish`, then builds both architectures from that
worktree. It shows both `release.json` receipts and runs the native `tilrd --version`.
Inspect/test both artifacts, then type exactly `publish` to publish. Refusal or
EOF leaves artifacts available without publication. After publication, both signed
CDN feeds are checked and the JSON pin for `server-release.json` is printed;
copy it into that file separately. `--channel beta` selects the beta feeds.
The worktree is removed on exit; the original clone checkout is preserved.
No credentials are created and no login is initiated. If a step fails, later
steps stop. After declining publication, use the lower-level `--publish-only`
command below with the same version/build and channel to publish inspected artifacts.

The lower-level commands remain available:

The server build machine needs Rust, Zig 0.15.2, protoc, Apple signing/notarization
credentials from `release.local.json`, and the Rust targets:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
python3 scripts/release_server.py --version 0.1.0 --build 1
# Rebuild from a checkout you have prepared at the intended tag:
python3 scripts/release_server.py --version 0.1.0 --build 2 --source /path/to/tagged-tilrd
# Test both completed artifacts, then publish without rebuilding:
python3 scripts/release_server.py --version 0.1.0 --build 1 --publish-only
```

`--source PATH` selects the tilrd source checkout for a lower-level build, including
the protocol version read at build time. It defaults to `../tilrd` relative to
the desktop repository. This command builds that checkout's current sources; it
does not select a tag automatically. Prepare the intended tag yourself before
rebuilding, or use the complete tagged-source workflow above. `--publish-only`
uses completed artifacts without reading or rebuilding the source checkout.

`--arch arm64` or `--arch x86_64` selects one architecture; the default is both.
`--channel beta` selects the server beta feed independently of the app channel.
`--min-app-build` / `--max-app-build` constrain native-client compatibility when
needed. The protocol version is read from the server source at build time.
`--preview` creates ad-hoc local artifacts which cannot be published or bundled
in a public app. Build output is `build/server-releases/<version>-<build>-<arch>`
(with `-preview` for previews). A failed/incomplete directory is never reused;
inspect and move it aside before retrying the same unpublished number.

The server executable is Developer ID signed and notarized before its completion
receipt is written. Publication checks the receipt/checksum, preserves immutable
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
point to the same downloaded artifacts on another build machine. Public app
builds require public server artifacts. Preview app builds may use preview server
artifacts when no public artifact for the pin exists. App releases remain two
separate architecture DMGs; universal server artifacts are not used.

The app records its supported server protocol, bundled server identity, server
feed base URL and public verification key in its signed Info.plist. Downloads
are selected by server build within the supported protocol, architecture and app
build range; hashes/signatures are verified before replacement. The app installs
the replacement binary and requests reload; tilrd checks reload-state compatibility
before handing over. The app confirms the update through `ps --server-version`.
If reload is refused and the running version stays unchanged, the app reports
"The local server did not become ready. Reload did not complete: running version
X, expected Y" with the server log path and confirmation that existing processes
were not stopped. The supervisor and terminals keep running, and the replacement
binary remains installed. To use that binary after a refused reload, stop the
service, then start it again; this ends the existing terminal sessions.
The next application build can still bundle an older compatible server; it will
not undo an independent server update.

### Runtime and controls

The default instance installs into
`~/Library/Application Support/dev.tilr.mac/server/` and creates
`~/Library/LaunchAgents/dev.tilr.server.plist`. It listens on loopback port 7890,
with private managed state/token and runtime files. The job runs the signed
`tilrd` directly (no shell wrapper); panes get the user's login environment
because the server starts their shell as a login shell (server 0.1.0 build 3+).
The plist's `AssociatedBundleIdentifiers` (the app's bundle id, `dev.tilr.mac`) makes Login
Items and the "Background Items Added" notice show the job as Tilr rather than the signing team
(macOS 13+; the binary and the app must share a Team ID); a job lacking the key is migrated like
a zsh one below.
A plist of ours with another definition (a job written by an earlier Tilr through
`/bin/zsh -lc 'exec …'` or without the association, a changed port or environment) is
rewritten and applied. "Ours" = Label `dev.tilr.server` and `ProgramArguments` running the
installed `tilrd`, directly or through `/bin/zsh -lc`; any other plist under that name,
or a loaded job of that name without the file, is refused with a message naming the file.
launchd keeps a loaded definition until bootout, so applying it means a restart:
- the job is stopped, or the server reports no live panes → `bootout` + `bootstrap` at once,
  then the usual wait for the port;
- the server has live panes, or does not answer → only the file is rewritten and
  `server/restart-pending` is written. `Tilr > Local Server…` then says "A new service
  definition is waiting; restart to apply" and offers Restart Server… (confirmation: open
  panes will close). The next launch applies it by itself if the server has no panes then.
  "Pending" is read from launchd: `launchctl print`'s program, arguments and environment
  (minus `OSLogRateLimit` and `XPC_*`, which launchd adds) against the plist; a login that
  loaded the new file counts as applied and clears the marker. The marker decides only when
  that output cannot be parsed.
"Live panes" comes from `tilrd ps --url ws://127.0.0.1:<port>` (the protocol's
ListPanes over the server's WebSocket, with the stored token): a header plus one line per pane.
After every `bootstrap`, a job that `launchctl print` shows loaded without a `pid` is
`kickstart`ed. Standalone installations are
not adopted or stopped; conflicting ports/services produce a visible error.
The generated `origins.toml` allows configured Tilr app origins. Config changes
are applied on app launch through a session-preserving reload.

`Tilr > Check for Updates…` checks the **application**.
`Tilr > Check for Server Updates…` checks the **server** and offers Update Server.
`Tilr > Local Server…` shows the installed version/channel, any available update, a pending
service definition (Restart Server…) and Remove Local Server…, and while Tilr works, the
launchd step it is on.
Opening it performs an authenticated connection check off the UI thread and shows
"Running" with the actual running version, or "Not running or unreachable" when the
server cannot be reached. "Refresh" repeats the check; connection failure
is not treated as proof that the process has exited.
By default server checks run at launch and every 24 hours; installation requires
pressing Update Server. `local_server.update_channel`, `auto_check`,
`check_interval`, network timeouts and size limits are documented in `default.yml`.
A network/feed failure leaves the local server and credentials usable. A feed URL that answers
anything but 200 (404 before the first release of a channel) means "No server release is
published for <channel>/<arch>": a manual check says so, an automatic one only logs it. A
non-200 on the binary download is "Server update download failed (HTTP <status>)".

### Removal

`local_server.enabled: false` in `config.yml` (at launch, or on save: the config is watched), or
Remove Local Server… in `Tilr > Local Server…` (confirmation: open panes will close), removes
what the app installed when the plist is ours (see above): `launchctl bootout
gui/<uid>/dev.tilr.server`, the plist, and in `server/` the binary, `tilrd.previous`,
`app-managed*.json`, `origins.toml`, `runtime/` and a pending-restart marker. `server/state/`
(sessions, token, logs) and `server.log` stay. A foreign plist is left alone with a notice.
Only release builds (with a bundled server) remove, as only they install. The dialog then
shows "Not installed"; the next launch with `enabled: true` (or setting it back to `true`)
installs afresh from the bundle.

macOS's Background Task Management database keeps its record of the agent after the plist is
gone (`sfltool dumpbtm` still lists `8.dev.tilr.server`): launchd no longer knows the job and
nothing runs, but there is no public API to delete one legacy agent's record.

By hand, when the app is already gone:

```sh
launchctl bootout gui/$(id -u)/dev.tilr.server     # stops the server; its panes close
rm ~/Library/LaunchAgents/dev.tilr.server.plist
rm -rf ~/Library/Application\ Support/dev.tilr.mac/server   # binary, receipts, state (sessions, token, logs)
# Everything of the app: rm -rf ~/Library/Application\ Support/dev.tilr.mac
```
The managed server's `update` command points to this independent server updater.
The separate Linux/standalone server updater is unchanged.

Installation replaces the binary atomically at a fixed path and waits for an
authenticated response with the expected running version. It never stops a
running supervisor to upgrade. The server's reload preserves sessions; the old
binary and its receipt remain as `tilrd.previous` and
`app-managed.previous.json` for manual recovery, not automatic live rollback. A
transaction journal reconciles interruptions before/after binary replacement on
the next launch, even when that app bundles an older server. Closing the app leaves terminals running until logout.
The server plugin receives credentials only through its trusted top-level
`tilr://` bridge; remote profiles/defaults are preserved. Existing external site
folders still need the rebuilt server plugin; no separate web-site updater is
introduced. Test/probe/custom-config instances never manage the production server.

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
