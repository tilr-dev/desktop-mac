## MODIFIED Requirements

### Requirement: One-command independent server release
The desktop repository SHALL provide a tagged-source server release command with credential-free preview. It SHALL validate the tagged protocol, preflight access, and build both signed and notarized macOS architectures. It SHALL show artifacts and require explicit confirmation before publishing, verify both channel feeds, and print the app pin. Failures SHALL stop later steps.

#### Scenario: Release tagged sources
- **WHEN** the command receives --version, --build, --min-app-build, and an exact existing --tag
- **THEN** it builds the detached tagged sources even when the source clone HEAD differs
- **AND** it runs release_all.py --check --publish with Homebrew first in PATH before building both architectures

#### Scenario: Select sources for a lower-level build
- **WHEN** the operator runs release_server.py with --source PATH
- **THEN** it builds the checkout at PATH and reads the protocol version from that checkout
- **AND** it uses that checkout's current sources without selecting a tag automatically

#### Scenario: Default sources for a lower-level build
- **WHEN** the operator runs release_server.py without --source
- **THEN** it builds the current sources in ../tilrd relative to the desktop repository
- **AND** it does not select a tag automatically

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
- **WHEN** the tag, protocol, preflight, build, or feed verification is invalid or fails
- **THEN** the command exits unsuccessfully without proceeding to later release steps
