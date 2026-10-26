## ADDED Requirements

### Requirement: One-command independent server release
The desktop repository SHALL provide a command accepting a server version, build, minimum app build, and tilrd tag. It SHALL prepare a detached worktree of that tag, read and validate its PROTOCOL_VERSION, and build using those sources. It SHALL preflight release access with Homebrew Node version 22 or newer, then build, sign, and notarize both macOS architectures using the existing release tools. It SHALL display release metadata and the built server version before requesting explicit publication confirmation. After confirmation it SHALL publish, verify both architecture feeds for the requested channel, and print the JSON pin for server-release.json. Failures SHALL stop subsequent steps.

#### Scenario: Release tagged sources
- **WHEN** the command receives valid release arguments and an existing tag
- **THEN** it builds the detached tagged sources even when the source clone HEAD differs
- **AND** it preflights access before building both architectures

#### Scenario: Inspect before publishing
- **WHEN** the signed artifacts are ready
- **THEN** the command displays release.json and the built server version
- **AND** no publication occurs unless the operator explicitly confirms
- **AND** refusal or end of input leaves the artifacts available for inspection

#### Scenario: Confirm publication
- **WHEN** the operator confirms publication
- **THEN** the command publishes the prepared artifacts and verifies both channel feeds
- **AND** it prints the version, build, and tagged protocolVersion as a JSON app pin

#### Scenario: Credential-free preview
- **WHEN** the operator selects --preview
- **THEN** the command validates the tag and protocol and shows the planned commands and pin
- **AND** it does not require credentials, build, sign, notarize, or publish

#### Scenario: Invalid input or failed step
- **WHEN** the tag, protocol, Node version, preflight, build, or feed verification is invalid or fails
- **THEN** the command exits unsuccessfully without proceeding to later release steps
