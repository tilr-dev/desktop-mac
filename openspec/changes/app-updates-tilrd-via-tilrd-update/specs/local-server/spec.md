## MODIFIED Requirements

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

### Requirement: Explicit server update controls
Tilr SHALL show the installed tilrd version and an Update tilrd button in Local Server and SHALL update the selected ordinary daemon by running its own update command. The application SHALL NOT consume a server update feed or replace installed executables to update them.

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

## REMOVED Requirements

### Requirement: Authenticated and compatible replacement
**Reason**: The ordinary daemon owns downloads, verification and replacement through its update command.
**Migration**: Use Update tilrd in Local Server; retain offline bootstrap and its installation journal.
