# Releases operated by an agent

**Current default workflow:** see [PRODUCTION.md](PRODUCTION.md): `setup-release.command` configures credentials only; `release.command` builds only; `upload.command` publishes the last completed tested app pair without rebuilding; explicit `release_all.py --publish-only` remains supported. `release.command --status` displays local history without Keychain access or build reservations. The combined `--publish` mode below remains an explicit shortcut.

## Product decision

Ship **two separate DMGs per release**, with the same marketing version and build:

| Website button | Architecture | Stable feed |
| --- | --- | --- |
| Download for Apple Silicon | arm64 | https://cdn.tilr.dev/mac/arm64/appcast.xml |
| Download for Intel | x86_64 | https://cdn.tilr.dev/mac/x86_64/appcast.xml |

Do not default to Universal. The website should keep both buttons visible, with
“Check Apple menu → About This Mac” as a hint. Each installed app reads only its
architecture's feed. Beta uses `/mac/beta/<arch>/appcast.xml`.

The website implementation is outside this repository. The release command writes
`build/releases/<version>-<build>-<channel>-downloads.json` with both immutable DMG
URLs after BOTH publications are verified. Use those URLs for the website buttons;
do not label proposed URLs as live before a successful upload. No website files or
live website deployment are changed by these scripts.

## One-time setup on the release Mac

Use `PRODUCTION.md` and `setup-release.command` for the interactive bootstrap. This is a
one-time human task, not the command an automated agent should run on every release.

- macOS 14+, Xcode/Swift, Python 3.11+, Node >=22 and Wrangler.
- Rexuni LLC Developer ID Application certificate **and its private key**, in a
  Keychain accessible to the release process. The certificate was created in Xcode
  on 2026-10-11; do not create/revoke another merely because a sandbox cannot see it.
- Notarization credentials stored with `xcrun notarytool store-credentials
  tilr-rexuni`. Apple ID/app-specific password or the supported Apple API key flow.
- Sparkle key generated once with `generate_keys --account tilr-rexuni`; keep the
  private key in Keychain. All architectures use the same public key.
- Cloudflare authorization for the existing account
  `8e0530af975a33f2f739127f75084531`, R2 bucket `tilr-cdn`. Local setup can use
  `wrangler login`. A dedicated runner can use a scoped deployment token provided
  by its secret store, rather than interactive login.
- `release.local.json` contains the full identity, Keychain profile name and public
  Sparkle key. Copy the shape from `release.local.example.json` if configuring
  manually. No passwords or private keys belong in this file or Git. Environment
  variables override these settings. `release_all.py` derives each feed from
  architecture/channel, ignoring a leftover single-architecture `TILR_UPDATE_FEED`.

The agent must execute under an OS/tool permission profile that allows THIS release
process to use the Keychain, code signing, disk image creation, and network access
to source dependencies, Apple notarization and Cloudflare. A repository script
cannot grant those permissions. Do not bypass a restricted tool environment by
launching commands through UI automation, another account, or another tool.

When local agent execution is restricted, use an explicitly configured macOS release
runner (for example a dedicated self-hosted CI runner) with the above credentials,
and give the agent permission to trigger and inspect its release jobs. This repo
does not provision that runner or change agent permissions. Prefer a controlled
release command/job over unrestricted access to the machine. An unattended runner
must already have access to the required keys; interactive Keychain prompts cannot
be answered by these scripts. Never enable blanket private-key access to fix a prompt.

## Agent commands

From `apps/mac`, first verify the actual execution context:

```sh
python3 scripts/release_all.py --check --publish
```

This checks tool availability, Node version, the configured identity, notarization
profile, Sparkle key, an actual temporary code-signing operation, disk-image creation,
and access to the R2 bucket. It creates no release and publishes nothing. It uses
existing credentials only; it does not create keys or start login flows.

On the current Apple Silicon development Mac, `/usr/local/bin/node` can select old
Node 18 while `/opt/homebrew/bin/node` is newer. Set PATH for the process if needed:

```sh
PATH="/opt/homebrew/bin:$PATH" python3 scripts/release_all.py --check --publish
```

When the user explicitly requests combined build and publication, use the following
shortcut. For the default build → local test → publish workflow, follow PRODUCTION.md:

```sh
python3 scripts/release_all.py --version 0.1.0 --build 1 --channel stable --publish
```

The script builds and notarizes arm64, then x86_64. Both complete before publication
starts. It prepares and validates both appcasts, then publishes the feeds in sequence.
Signing keys are used in place; no secret is printed or put in a command argument.
An optional `--notes /absolute/path/changes.txt` embeds release notes in each feed.
Without `--publish`, both notarized DMGs are built but nothing is uploaded.

For subsequent releases increment build, e.g. `--version 0.1.1 --build 2`. The build
must exceed every published build in the chosen channel. Do not invent a release
version that conflicts with the user's release request or the existing feeds.

## Failure and recovery

If a build fails, neither architecture is published by the coordinator. Successful
local builds have `release.json`; incomplete output directories do not. Preserve
the failed output for diagnosis (move it aside before rebuilding with the same
version/build). Never reuse incomplete artifacts as a completed release.

If a feed upload fails after the other feed was published, retry:

```sh
python3 scripts/release_all.py --version 0.1.0 --build 1 --channel stable --publish --resume
```

`--resume` reuses only completed builds matching version, architecture, channel and
key, and verifies their hashes. An already-published build is accepted only after
checking its feed metadata/signature and downloading the exact matching DMG. A
different archive at the same URL or a newer published build is an error.

Two R2 feed writes are **not atomic**. A failure between them can temporarily offer
the new version to one architecture only. Do not report the whole release complete
until both feeds are verified and the downloads summary exists. Publish serially
from one release checkout; the local lock does not coordinate different machines.

## Evidence to report

Return the two verified download URLs, version/build/channel, and the test status.
Keep a distinction between compiling Intel code and running it on an Intel Mac.
Before first public handoff, test installation from a browser download on a clean
Mac and a real Sparkle upgrade from build N to N+1 on the beta feeds. Preserve user
configuration and external site folders. Do not restart the user's running Tilr
for release tests; use its separate test instance/configuration.

If blocked by Keychain, network or disk-image permissions, name the failing command
and report what actually completed. Do not claim a signed DMG, live download, or
working auto-update from compilation/unit tests alone.
