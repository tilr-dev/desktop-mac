## MODIFIED Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, verification and publication in CI, preserving the exact tested artifacts. Local development builds SHALL remain available without a local release publication command.

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the pinned upstream server without compilation or signing and builds both DMGs, and its publish job publishes those same files as an RC to beta after a release/X.Y push or to stable from the stable tag created by merging the release PR, without rebuilding them in the publish job
- **AND** release_all.py packages explicit CI version/build inputs without publication, local build reservations or a saved last-release selection

#### Scenario: Default commands
- **WHEN** the CI build job invokes release_all.py
- **THEN** explicit version/build/channel inputs package both architectures without publishing; CI provisions credentials separately

#### Scenario: Saved stable upload selection
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

#### Scenario: Inspect or reserve
- **WHEN** CI resolves a release build
- **THEN** it inspects all stable and beta appcasts and passes one explicit build to packaging without writing a local reservation

#### Scenario: No release version in the template
- **WHEN** the source Info.plist contains `0.0.0-dev`
- **THEN** CI uses the numeric release-please version explicitly without changing the source template or consulting local history

#### Scenario: CI release numbers
- **WHEN** the Release workflow runs on a runner without local history
- **THEN** it takes the numeric version from the shared release-please workflow, resolves build as the highest build in both architecture appcasts across stable and beta plus one, and passes these explicitly to packaging and publication
- **AND** no local reservation, remembered version or last-completed-release file is required or written

### Requirement: Verified upstream server artifacts
fetch_server.py SHALL acquire signed and notarized macOS tilrd and tilr from the same pinned upstream GitHub Release independently from application releases, writing completion receipts only after verification of both executables.

#### Scenario: Acquire and verify pinned server artifacts
- **WHEN** the pinned version is requested
- **THEN** CI acquires both architectures using the exact server-release.json pin
- **AND** tilr-v<version>-<target>.tar.gz from tilr-dev/tilrd has its published SHA-256 verified before extracting either executable
- **AND** both binaries have their architecture, Developer ID signature, expected Apple team, secure timestamp and matching version verified before completion
- **AND** a missing client, bad checksum, unsafe archive, unexpected architecture, signature or version stops acquisition without a completed receipt or source-build fallback
- **AND** no Rust, Zig, protoc, source checkout or Apple signing/notarization credentials are required
- **AND** fetch_server.py exits with code 1 on missing or invalid upstream assets
- **AND** server-release.json pins the upstream version and protocol; completion metadata retains the pinned artifact revision for bundling without feed channels or configurable app-build ranges
- **AND** TILR_SERVER_RELEASE_ROOT may supply completed artifacts, which are verified before use
- **AND** application packaging copies both executables and exact server manifest without compiling, stripping or re-signing either executable

#### Scenario: Verify inline code signing requirements
- **WHEN** an upstream macOS server is checked before import
- **THEN** codesign receives the inline Apple trust, Developer ID certificate and team requirement as one -R=<requirement> argument
- **AND** an invalid signature, unexpected team, missing Developer ID authority or missing secure timestamp stops acquisition

#### Scenario: Inspect the version in optimized upstream binaries
- **WHEN** Rust stores the upstream version/platform immediately after another string literal
- **THEN** acquisition recognizes the full version/platform without requiring a delimiter before the version
- **AND** a different full release number is rejected even when it contains the pinned version as a suffix

## REMOVED Requirements

### Requirement: One-command upstream server acquisition
**Reason**: CI fetches and verifies the automatic upstream pin directly; a manual acquisition wrapper is redundant.
**Migration**: Use fetch_server.py in CI with server-release.json updated by the upstream release PR.

### Requirement: Server release version format
**Reason**: The two local server release commands are removed.
**Migration**: CI consumes the exact version in the automatically updated server-release.json pin.
