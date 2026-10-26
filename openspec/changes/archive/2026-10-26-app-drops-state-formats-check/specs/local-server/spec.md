## MODIFIED Requirements

### Requirement: Authenticated and compatible replacement
Tilr SHALL authenticate signed server feed metadata and downloaded bytes before replacing an installed binary, selecting only compatible newer builds.

#### Scenario: Install an update
- **WHEN** a server update is chosen
- **THEN** CryptoKit verifies server-feed Ed25519 signatures with the existing app release public key embedded in the signed app bundle (currently shared between app and server feeds); verification covers explicit component/architecture/channel metadata; protocol, app-build range, architecture, size limits and SHA-256 are checked before replacement
- **AND** the binary is staged privately and its size/hash verified before executable use; malformed feeds and same-build changed manifests are rejected
- **AND** fixed-path replacement is atomic, explicitly requests session-preserving reload of the running supervisor after the rename, and waits for an authenticated expected-version response without stopping the running supervisor; sessions survive reload
- **AND** the app does not invoke `tilrd state-formats`; tilrd checks reload-state compatibility before handing over, and an incompatible live-state migration leaves the old supervisor and its terminals running
- **AND** tilrd.previous and app-managed.previous.json remain for manual recovery, not automatic live rollback; a transaction journal reconciles interrupted replacement on next launch even from an app with an older bundle
- **AND** closing Tilr leaves terminals running until logout; the managed server update command points to this updater without changing standalone/Linux updating

#### Scenario: Reload request fails after installation
- **WHEN** the new server binary has been installed but the explicit reload request fails
- **THEN** the new binary and its receipt remain installed and the previous binary and receipt remain available for manual recovery, without automatic rollback
- **AND** Local Server reports that the update was installed but the server was not reloaded
- **AND** the app does not stop the running supervisor or report the update as ready

#### Scenario: Resume an interrupted replacement
- **WHEN** the app resumes after replacement completed but before reload was requested, including after a failed request
- **THEN** it reconciles the installed receipt and explicitly requests reload of a running supervisor before waiting for an authenticated expected-version response
- **AND** it keeps the replacement transaction pending until the reload request or service start succeeds

#### Scenario: Install with no running supervisor
- **WHEN** an update is installed and the owned job is unloaded or stopped
- **THEN** the app bootstraps or starts the job with the installed binary and waits for an authenticated expected-version response
- **AND** it does not send a reload request to an absent supervisor

#### Scenario: Validate daemon identity
- **WHEN** an installation candidate is validated or a signed server feed is read
- **THEN** the executable version starts with `tilrd <version> (` and the feed component is `tilrd`
- **AND** other executable identities or feed components are rejected before installation

#### Scenario: Supervisor refuses reload
- **WHEN** the app requests reload after installing an update and authenticated `tilrd ps --server-version` continues to report the previous running version until the readiness deadline
- **THEN** Local Server reports that the installed update did not become ready and includes the running and expected versions
- **AND** the app leaves the running supervisor and its terminals untouched and does not report the update as complete

#### Scenario: Supervisor accepts reload
- **WHEN** the app requests reload and authenticated `tilrd ps --server-version` reports the expected new version
- **THEN** the update completes without stopping the supervisor or its terminals
