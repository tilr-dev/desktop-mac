## MODIFIED Requirements

### Requirement: Offline bootstrap and independent updates
Tilr SHALL bundle unchanged signed/notarized tilrd and tilr executables from the same upstream GitHub Release pinned by server-release.json, and SHALL use one ordinary local tilrd installation shared with the terminal client.

#### Scenario: Find an existing installation
- **WHEN** local_server is enabled at application launch
- **THEN** discovery checks a running server on the default socket first, tilrd in the login shell PATH second, and ~/.local/bin/tilrd third
- **AND** an existing installation is used without installing bundled executables or creating an application installation marker
- **AND** incompatible servers are reported without stopping or replacing them

#### Scenario: Start offline or with a newer installation
- **WHEN** no ordinary tilrd installation is found
- **THEN** the bundled matching tilrd and tilr are installed into ~/.local/bin without network access or build tools
- **AND** tilr service install starts the ordinary service and a persistent marker records that the application installed it
- **AND** a durable pair-installation journal recovers interruptions before or between executable publication and ownership marker creation
- **AND** application and server version/build/channel tracks remain independent

### Requirement: Managed service ownership and configuration
Tilr SHALL connect to the ordinary local tilrd on port 7890 using its default state directory and sh.tilr.tilrd launchd service, without maintaining a private daemon copy, private state directory or dev.tilr.server launchd job.

#### Scenario: Install or reconfigure
- **WHEN** an installed daemon is not running
- **THEN** Tilr uses tilr service install to start its ordinary launchd service and waits for authenticated readiness
- **AND** credentials are obtained using tilr token with the default state directory
- **AND** probe, test and custom-config instances do not install or reconfigure the production service

#### Scenario: Reinstall an old private installation
- **WHEN** an application with ordinary-daemon support replaces a private-daemon application
- **THEN** no migration of the private service or its state is performed; reinstallation is required

### Requirement: Authenticated and compatible replacement
Tilr SHALL authenticate signed server feed metadata and downloaded bytes before replacing an installed binary, selecting only compatible newer builds at the ordinary daemon installation path.

#### Scenario: Install an update
- **WHEN** a server update is chosen
- **THEN** Ed25519 metadata signatures, component, architecture, channel, protocol, app-build range, size and SHA-256 are checked before executable use
- **AND** replacement is atomic and explicitly requests session-preserving reload through tilrd reload, including for ordinary servers launched outside launchd, waiting for an authenticated expected-version response
- **AND** tilrd checks reload-state compatibility; the application does not invoke tilrd state-formats
- **AND** the previous binary and receipt remain for manual recovery and a transaction journal reconciles interrupted replacement

#### Scenario: Reload request fails after installation
- **WHEN** replacement succeeded but reload fails
- **THEN** the new binary and receipt remain installed, the previous artifacts remain available, and the transaction remains pending until reload or ordinary service start succeeds
- **AND** a running supervisor and its sessions are not stopped or rolled back, and the UI reports failure to become ready

#### Scenario: Resume an interrupted replacement
- **WHEN** the app resumes after the binary rename but before a successful reload request
- **THEN** it reconciles the receipt and requests reload of a live daemon before waiting for authenticated expected-version readiness
- **AND** it retains the transaction until reload or ordinary service start succeeds

#### Scenario: Install with no running supervisor
- **WHEN** replacement has no running supervisor
- **THEN** the ordinary service is started and authenticated readiness is awaited without requesting reload of an absent supervisor

#### Scenario: Supervisor refuses reload
- **WHEN** the running daemon continues to report the previous version after reload until the readiness deadline
- **THEN** the previous and expected versions are reported as not ready without stopping sessions

#### Scenario: Supervisor accepts reload
- **WHEN** the running daemon reports the expected new version after reload
- **THEN** the update completes without stopping the supervisor or its terminals

#### Scenario: Validate daemon identity
- **WHEN** an installation candidate or server feed is validated
- **THEN** the executable identity starts with tilrd <version> ( and the feed component is tilrd; other identities are rejected

### Requirement: Removal preserves user state
Tilr SHALL preserve ordinary daemon user state, sessions, token and logs when local-server support is disabled or removal is requested, and SHALL use the application installation marker to distinguish an application-installed daemon from a pre-existing installation.

#### Scenario: Disable or remove
- **WHEN** local_server.enabled becomes false
- **THEN** application integration stops without deleting default daemon state or claiming a pre-existing installation as application-owned

#### Scenario: Remove an application-installed pair
- **WHEN** the user confirms removal and the marker identifies the selected daemon path
- **THEN** tilr service uninstall removes ordinary startup registration and the application removes its installed executable pair and marker
- **AND** default state, token, logs and existing running sessions remain untouched
- **AND** pre-existing installations are not removed

### Requirement: Trusted credential delivery
Tilr SHALL provide ordinary local-server credentials obtained through tilr token only to its trusted top-level app page while preserving remote profiles and defaults.

#### Scenario: Request credentials
- **WHEN** the owning main app web view requests local-server access
- **THEN** it receives the token for the same default daemon used by the terminal tilr client on port 7890
- **AND** embedded browser pages, subframes and wrong origins are rejected with the app-page restriction
- **AND** external site folders require their rebuilt server plugin; no web-site updater is introduced

## REMOVED Requirements

### Requirement: Safe launchd definition migration
**Reason**: The ordinary daemon service replaces application-owned launchd definitions; existing private installations require reinstallation.
**Migration**: Reinstall instead of migrating private service definitions or state.
