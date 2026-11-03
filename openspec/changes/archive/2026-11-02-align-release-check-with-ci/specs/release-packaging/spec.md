## MODIFIED Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, verification and publication in CI, preserving the exact tested artifacts. Local development builds SHALL remain available without a local release publication command.

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the latest stable upstream server release without compilation or signing, installs the pinned gitpm release without compiling it, and builds both DMGs, and its publish job publishes those same files as an RC to beta after a release/X.Y push or to stable from the stable tag vX.Y.Z pushed by Dan using bin/release, without rebuilding them in the publish job
- **AND** release_all.py packages explicit CI version/build inputs without publication, local build reservations or a saved last-release selection

#### Scenario: CI packaging inputs
- **WHEN** the CI build job invokes release_all.py
- **THEN** explicit version/build/channel inputs package both architectures without publishing; CI provisions credentials separately

#### Scenario: CI stable publication selection
- **WHEN** the CI publisher selects stable
- **THEN** it uses the verified workflow tag and explicit metadata rather than a saved local upload selection

#### Scenario: Build-only publication guidance
- **WHEN** packaging completes
- **THEN** it reports the completed artifact directories without suggesting a local upload command

#### Scenario: Local development
- **WHEN** a developer builds or tests locally
- **THEN** run.sh and the artifact verifier remain available without configuring a local release workflow

### Requirement: Persistent release numbering
CI SHALL allocate monotonically increasing application builds from published appcasts, independently of marketing-version changes and local history.

#### Scenario: CI build allocation
- **WHEN** CI resolves a release build
- **THEN** it inspects all stable and beta appcasts and passes one explicit build to packaging without writing a local reservation

#### Scenario: No release version in the template
- **WHEN** the source Info.plist contains `0.0.0-dev`
- **THEN** CI uses the numeric version from the verified selected tag, stripping v and any RC suffix explicitly without changing the source template or consulting local history

#### Scenario: CI release numbers
- **WHEN** the Release workflow runs on a runner without local history
- **THEN** it takes the numeric version from the selected tag provided by the shared release workflow, stripping v and any RC suffix, resolves build as the highest build in both architecture appcasts across stable and beta plus one, and passes these explicitly to packaging and publication
- **AND** no local reservation, remembered version or last-completed-release file is required or written
