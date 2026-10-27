## MODIFIED Requirements

### Requirement: Removal preserves user state
Tilr SHALL preserve ordinary daemon user state, sessions, token and logs when local-server support is disabled or removal is requested, and SHALL use the application installation marker to distinguish an application-installed daemon from a pre-existing installation. A matching marker SHALL authorize daemon removal; an unmarked installation SHALL require explicit user consent.

#### Scenario: Disable integration
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

## ADDED Requirements

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
