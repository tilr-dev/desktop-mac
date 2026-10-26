## ADDED Requirements

### Requirement: Protocol one application distribution
The application distribution SHALL support server protocol 1 using the protocol metadata of its completed bundled server in signed Info.plist, and SHALL reject servers with other protocol versions.

#### Scenario: Install and update a protocol one server
- **WHEN** the app bundles a completed protocol 1 server and reads a signed feed containing newer servers of protocols 1 and 2
- **THEN** the bundled server installs and only the compatible protocol 1 release is selected
- **AND** protocol 2 candidates are skipped without replacing the working server
- **AND** a signed feed with invalid protocol 0 metadata is rejected

#### Scenario: Validate packaged protocol metadata
- **WHEN** a protocol 1 app release is validated for publication
- **THEN** its bundled server protocol matches TilrServerProtocolVersion in signed Info.plist
- **AND** a bundled server of protocol 0 or 2 is rejected when app metadata specifies protocol 1
