## MODIFIED Requirements

### Requirement: Offline bootstrap and independent updates
Tilr SHALL bundle unchanged signed/notarized tilrd and tilr executables from the same upstream GitHub Release, the latest stable release when the application is built, and SHALL use one ordinary local tilrd installation shared with the terminal client. The bundled pair SHALL be only a starting point for an absent installation and an offline fallback; its version SHALL NOT limit or select the installed version.

#### Scenario: Find an existing installation
- **WHEN** local_server is enabled at application launch
- **THEN** discovery checks a running server on the default socket first, tilrd in the login shell PATH second, and ~/.local/bin/tilrd third
- **AND** an existing installation is used without installing bundled executables or creating an application installation marker, including when it is older than the bundled pair
- **AND** incompatible servers are reported with an Update tilrd action without stopping or replacing them through application file operations

#### Scenario: Start offline or with a newer installation
- **WHEN** no ordinary tilrd installation is found
- **THEN** the bundled tilrd and tilr are installed into ~/.local/bin without network access or build tools, after verifying both signatures and that both report the same version
- **AND** tilr service install starts the ordinary service and a persistent marker records that the application installed it
- **AND** a durable pair-installation journal recovers interruptions before or between executable publication and ownership marker creation
- **AND** application and daemon versions remain independent; daemon updates use the channel configured in server.toml, defaulting to stable

#### Scenario: Update to the latest release at launch
- **WHEN** the application starts with local_server enabled, including the first launch after a Sparkle application update and after installing the bundled pair
- **THEN** after the selected daemon is ready, the application runs that tilrd's update command without a channel argument, off the UI thread without asking
- **AND** the existing credentials stay usable while the command runs; after it succeeds the application waits for the reported version to be running and rechecks it
- **AND** an already latest daemon is left running unchanged
- **AND** an unavailable CDN or a failed command leaves the installed pair running and is shown in Local Server without an alert, so an offline launch keeps the bundled or installed version
- **AND** an update that leaves the ready daemon speaking a newer protocol than the application is reported with an alert asking the user to update Tilr
- **AND** a daemon reported as speaking a newer protocol than the application is not updated at launch

#### Scenario: Validate daemon identity
- **WHEN** an installed daemon candidate is discovered
- **THEN** its executable identity starts with tilrd <version> ( and other identities are rejected

### Requirement: Explicit server update controls
Tilr SHALL show the installed tilrd version and an Update tilrd button in Local Server and SHALL update the selected ordinary daemon by running its own update command, which installs the latest tilrd and tilr of the channel configured in server.toml, defaulting to stable. The application SHALL NOT consume a server update feed, compare the daemon with the bundled version or replace installed executables to update them.

#### Scenario: Inspect and check
- **WHEN** Local Server opens or Refresh is selected
- **THEN** an authenticated check runs off the UI thread and shows the installed and running tilrd versions or Not running or unreachable
- **AND** Local Server offers Update tilrd for the selected installation and shows a prompt when its protocol is incompatible

#### Scenario: Update using the daemon configuration
- **WHEN** Update tilrd is selected
- **THEN** the selected installed tilrd runs update without a channel argument
- **AND** tilrd reads the channel from server.toml; Receive RC versions controls only the Sparkle feed for Tilr.app
- **AND** the command runs off the UI thread and application file operations do not replace the daemon

#### Scenario: Prompt for an older daemon
- **WHEN** the running daemon's protocol is incompatible with the application
- **THEN** Local Server shows the daemon and application protocols and asks the user to update Tilr when the daemon's protocol is newer, or to update tilrd with the same Update tilrd button when it is older
- **AND** a protocol error from a daemon just started by the application is reported as that prompt instead of a readiness timeout
- **AND** a compatible daemon of any version, older or newer than the bundled pair, remains usable without an update prompt

#### Scenario: Update fails or selects an older channel release
- **WHEN** the update command fails, including when the CDN or beta pointer is unavailable
- **THEN** the application preserves the existing daemon and credentials, reports the command error and leaves Update tilrd available for retry
- **WHEN** the command succeeds, including selecting an older RC from beta after a stable promotion
- **THEN** the application rechecks the actual installed and running versions and protocol before reporting readiness

