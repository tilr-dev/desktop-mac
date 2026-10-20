# local-server Specification

## Purpose
TBD - created by archiving change bootstrap-desktop-mac. Update Purpose after archive.

## Requirements

### Requirement: Offline bootstrap and independent updates
Tilr SHALL bundle an unchanged completed server pinned by server-release.json and maintain independent application and server version/build/channel tracks.

#### Scenario: Start offline or with a newer installation
- **WHEN** a public app starts
- **THEN** its bundled signed server can install offline without Node, npm, Git or a JavaScript CLI
- **AND** a newer compatible installed server wins; incompatible protocols/app-build ranges or reused build numbers with changed contents fail without stopping or downgrading it
- **AND** signed Info.plist metadata supplies the supported protocol, bundled identity, server feed base URL and verification key
- **AND** app Sparkle updates and `/server/macos/<arch>/<stable|beta>.json` server updates remain separate

### Requirement: Managed service ownership and configuration
The default release instance SHALL manage a loopback server under `~/Library/Application Support/dev.tilr.mac/server/` and `~/Library/LaunchAgents/dev.tilr.server.plist`, without adopting standalone installations.

#### Scenario: Install or reconfigure
- **WHEN** local_server is enabled (default true)
- **THEN** the service listens on configured loopback port (default 7890), keeps private state/token/runtime files and directly runs the signed binary without a shell wrapper; panes receive a login shell environment
- **AND** AssociatedBundleIdentifiers identifies the app, with app/server sharing a team; origins.toml permits configured app origins and config changes apply at app launch through session-preserving reload
- **AND** ownership requires label dev.tilr.server and installed-server ProgramArguments, directly or through the legacy zsh wrapper; a foreign plist, loaded job without its file or conflicting port is refused visibly
- **AND** probe, test and custom-config instances do not manage the production service; removal requires a release bundle containing the server

### Requirement: Safe launchd definition migration
Tilr SHALL migrate owned legacy or changed service definitions without silently closing live panes.

#### Scenario: Apply a new definition
- **WHEN** the plist needs a new direct program, association, port or environment
- **THEN** a stopped job or authenticated server reporting no live panes is booted out and bootstrapped immediately, with a loaded pidless job kickstarted and port readiness awaited
- **AND** a server with panes or unknown status gets a rewritten file and restart-pending marker; Local Server offers a confirmed restart warning that panes close
- **AND** pending state compares launchctl's loaded program/arguments/environment to the plist, ignoring OSLogRateLimit and XPC_* additions, using the marker only if parsing fails; a later login applying the file clears pending
- **AND** live-pane checks use authenticated `tilr-server ps --url ws://127.0.0.1:<port>`; connection failure does not prove process exit

### Requirement: Explicit server update controls
Tilr SHALL distinguish Check for Updates for the app from Check for Server Updates and require explicit Update Server approval to install a discovered server update.

#### Scenario: Inspect and check
- **WHEN** Local Server opens or Refresh is selected
- **THEN** an authenticated check runs off the UI thread and shows the actual running version or Not running or unreachable, installed version/channel, available update, pending restart/removal and current launchd step
- **AND** automatic checks default to launch and every 24 hours; channel, auto_check, interval, timeouts and limits come from default.yml
- **AND** feed/network errors preserve the working server and credentials; feed non-200 is No server release is published for the channel/arch (manual notice, automatic log), while binary non-200 is Server update download failed with HTTP status

### Requirement: Authenticated and compatible replacement
Tilr SHALL authenticate signed server feed metadata and downloaded bytes before replacing an installed binary, selecting only compatible newer builds.

#### Scenario: Install an update
- **WHEN** a server update is chosen
- **THEN** Ed25519 verification covers explicit component/architecture/channel metadata; protocol, app-build range, architecture, size limits, SHA-256 and reload-state compatibility are checked before replacement
- **AND** the binary is staged privately and its size/hash verified before executable use; malformed feeds and same-build changed manifests are rejected
- **AND** fixed-path replacement is atomic and waits for an authenticated expected-version response without stopping the running supervisor; sessions survive reload
- **AND** an incompatible live-state migration leaves the old service running until the user stops it
- **AND** tilr-server.previous and app-managed.previous.json remain for manual recovery, not automatic live rollback; a transaction journal reconciles interrupted replacement on next launch even from an app with an older bundle
- **AND** closing Tilr leaves terminals running until logout; the managed server update command points to this updater without changing standalone/Linux updating

### Requirement: Removal preserves user state
Tilr SHALL remove only its owned service and installed runtime artifacts, preserving state, sessions, token and logs.

#### Scenario: Disable or remove
- **WHEN** local_server.enabled becomes false at launch or on config save, or the user confirms Remove Local Server
- **THEN** the owned job is booted out and plist, binary, previous binary, managed receipts, origins, runtime and pending marker are removed; server/state and server.log remain
- **AND** a foreign plist is left alone with a notice; the dialog shows Not installed and enabling again installs from the bundle
- **AND** removal does not promise deletion of macOS Background Task Management history; manual full-directory removal is explicitly destructive to sessions/token/logs

### Requirement: Trusted credential delivery
Tilr SHALL provide managed-server credentials only to its trusted top-level app page while preserving remote profiles and defaults.

#### Scenario: Request credentials
- **WHEN** an embedded browser page, subframe or wrong origin requests local-server access
- **THEN** access is rejected with the app-page restriction; only the owning main app web view receives credentials
- **AND** external site folders require their rebuilt server plugin; no web-site updater is introduced
