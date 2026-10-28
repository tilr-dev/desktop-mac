# local-server Specification

## Purpose
Define offline bootstrap, ownership, independent authenticated updating and session-preserving management of the local terminal server.

## Requirements

### Requirement: Offline bootstrap and independent updates
Tilr SHALL bundle unchanged signed/notarized tilrd and tilr executables from the same upstream GitHub Release pinned by server-release.json, and SHALL use one ordinary local tilrd installation shared with the terminal client.

#### Scenario: Find an existing installation
- **WHEN** local_server is enabled at application launch
- **THEN** discovery checks a running server on the default socket first, tilrd in the login shell PATH second, and ~/.local/bin/tilrd third
- **AND** an existing installation is used without installing bundled executables or creating an application installation marker
- **AND** incompatible servers are reported with an Update tilrd action without stopping or replacing them through application file operations

#### Scenario: Start offline or with a newer installation
- **WHEN** no ordinary tilrd installation is found
- **THEN** the bundled matching tilrd and tilr are installed into ~/.local/bin without network access or build tools
- **AND** tilr service install starts the ordinary service and a persistent marker records that the application installed it
- **AND** a durable pair-installation journal recovers interruptions before or between executable publication and ownership marker creation
- **AND** application and daemon versions remain independent; daemon updates use the Receive RC versions preference to select stable or beta

#### Scenario: Validate daemon identity
- **WHEN** an installed daemon candidate is discovered
- **THEN** its executable identity starts with tilrd <version> ( and other identities are rejected

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

### Requirement: Explicit server update controls
Tilr SHALL show the installed tilrd version and an Update tilrd button in Local Server and SHALL update the selected ordinary daemon by running its own update command. The application SHALL NOT consume a server update feed or replace installed executables to update them.

#### Scenario: Inspect and check
- **WHEN** Local Server opens or Refresh is selected
- **THEN** an authenticated check runs off the UI thread and shows the installed and running tilrd versions or Not running or unreachable
- **AND** Local Server offers Update tilrd for the selected installation and shows a prompt when its version is older than the bundle pin or its protocol is incompatible

#### Scenario: Select the daemon update channel
- **WHEN** Update tilrd is selected
- **THEN** the selected installed tilrd runs update --channel stable when Receive RC versions is off, or update --channel beta when it is on
- **AND** the preference is read when the action starts, including changes made during the application session
- **AND** the command runs off the UI thread and application file operations do not replace the daemon

#### Scenario: Prompt for an older daemon
- **WHEN** the installed version is older than the bundled server pin or its protocol is incompatible with the application
- **THEN** Local Server shows the installed version and asks the user to update with the same Update tilrd button
- **AND** a protocol error from a daemon just started by the application is reported as an update prompt instead of a readiness timeout
- **AND** a compatible newer daemon remains usable without an update prompt

#### Scenario: Update fails or selects an older channel release
- **WHEN** the update command fails, including when the CDN or beta pointer is unavailable
- **THEN** the application preserves the existing daemon and credentials, reports the command error and leaves Update tilrd available for retry
- **WHEN** the command succeeds, including selecting an older RC from beta after a stable promotion
- **THEN** the application rechecks the actual installed and running versions and protocol before reporting readiness
- **AND** an installed version still older than the bundle pin keeps the update prompt instead of claiming the daemon is current

### Requirement: Removal preserves user state
Tilr SHALL preserve ordinary daemon user state, sessions, token and logs when local-server support is disabled or removal is requested, and SHALL use the application installation marker to distinguish an application-installed daemon from a pre-existing installation. A matching marker SHALL authorize daemon removal; an unmarked installation SHALL require explicit user consent.

#### Scenario: Disable or remove
- **WHEN** local_server.enabled becomes false
- **THEN** application integration stops without deleting default daemon state or claiming a pre-existing installation as application-owned

#### Scenario: Remove an application-installed pair
- **WHEN** the user selects Remove Local Server and the marker identifies the selected daemon in the application installation directory, including a symlinked directory
- **THEN** tilr service uninstall removes ordinary startup registration and the application removes its installed executable pair and installation metadata
- **AND** default state, token, logs and existing running sessions remain untouched

#### Scenario: Decline removal of an independently installed daemon
- **WHEN** the user selects Remove Local Server for an installation without a matching application marker
- **THEN** Tilr asks whether to remove tilrd
- **AND** choosing No leaves files, registration, running daemon and application integration unchanged

#### Scenario: Approve removal of an independently installed daemon
- **WHEN** the user answers Yes to the tilrd removal question
- **THEN** Tilr unregisters ordinary startup and removes the selected tilrd executable
- **AND** independently installed clients and ordinary daemon state, token, logs and existing running sessions remain untouched

### Requirement: Trusted credential delivery
Tilr SHALL provide ordinary local-server credentials obtained through tilr token only to its trusted top-level app page while preserving remote profiles and defaults.

#### Scenario: Request credentials
- **WHEN** the owning main app web view requests local-server access
- **THEN** it receives the token for the same default daemon used by the terminal tilr client on port 7890
- **AND** embedded browser pages, subframes and wrong origins are rejected with the app-page restriction
- **AND** external site folders require their rebuilt server plugin; no web-site updater is introduced

### Requirement: Protocol one application distribution
The application distribution SHALL support server protocol 1 using the protocol metadata of its completed bundled server in signed Info.plist, and SHALL reject servers with other protocol versions.

#### Scenario: Install and update a protocol one server
- **WHEN** the app bundles a completed protocol 1 server
- **THEN** the bundled server installs without reading a server update feed
- **AND** an installed server of another protocol is rejected for application connections and Local Server offers Update tilrd

#### Scenario: Validate packaged protocol metadata
- **WHEN** a protocol 1 app release is validated for publication
- **THEN** its bundled server protocol matches TilrServerProtocolVersion in signed Info.plist
- **AND** a bundled server of protocol 0 or 2 is rejected when app metadata specifies protocol 1

### Requirement: Uninstall Tilr…
Tilr SHALL offer Uninstall Tilr… in its application menu. After application-uninstall confirmation it SHALL apply the same marker and consent policy to tilrd, stop application-owned resources, clean application-owned data, move its application bundle to Trash, and quit.

#### Scenario: Uninstall with an application-installed daemon
- **WHEN** the user confirms Uninstall Tilr… and the application marker matches the selected daemon
- **THEN** the application-installed pair and installation metadata are removed, application resources and data are cleaned, and the bundle is moved to Trash
- **AND** ordinary daemon state, tokens, logs and existing sessions are preserved

#### Scenario: Uninstall with an independently installed daemon
- **WHEN** the user confirms Uninstall Tilr… with an unmarked daemon
- **THEN** Tilr asks whether to remove tilrd and applies the same Yes and No behavior as Remove Local Server
- **AND** declining daemon removal still allows application cleanup and trashing

#### Scenario: Removal or trashing fails
- **WHEN** daemon removal, application cleanup, or moving the bundle to Trash fails
- **THEN** Tilr reports the failure and does not report successful uninstall or quit

#### Scenario: Drag the application to Trash
- **WHEN** the user moves the application bundle to Trash outside Uninstall Tilr…
- **THEN** the shared tilrd continues running without an application deletion hook
