## MODIFIED Requirements

### Requirement: Removal preserves user state
Tilr SHALL preserve ordinary daemon user state, sessions, token and logs when local-server support is disabled or removal is requested, and SHALL use the application installation marker to distinguish an application-installed daemon from a pre-existing installation. A matching marker SHALL authorize daemon removal only after the user confirms Remove Local Server; an unmarked installation SHALL require explicit user consent.

#### Scenario: Disable or remove
- **WHEN** local_server.enabled becomes false
- **THEN** application integration stops without deleting default daemon state or claiming a pre-existing installation as application-owned

#### Scenario: Remove an application-installed pair
- **WHEN** the user confirms removal and the marker identifies the selected daemon in the application installation directory, including a symlinked directory
- **THEN** tilr service uninstall removes ordinary startup registration and the application removes its installed executable pair and installation metadata
- **AND** default state, token, logs and existing running sessions remain untouched

#### Scenario: Cancel removal of an application-installed pair
- **WHEN** the user selects Remove Local Server for an application-installed pair
- **THEN** Tilr asks “Remove the local server?” with Cancel and a destructive Remove button
- **AND** the dialog explains that the running server remains until it exits and state, token and logs are preserved
- **AND** choosing Cancel leaves files, startup registration, running daemon and application integration unchanged

#### Scenario: Decline removal of an independently installed daemon
- **WHEN** the user selects Remove Local Server for an installation without a matching application marker
- **THEN** Tilr asks whether to remove tilrd
- **AND** choosing No leaves files, registration, running daemon and application integration unchanged

#### Scenario: Approve removal of an independently installed daemon
- **WHEN** the user answers Yes to the tilrd removal question
- **THEN** Tilr unregisters ordinary startup and removes the selected tilrd executable
- **AND** independently installed clients and ordinary daemon state, token, logs and existing running sessions remain untouched

