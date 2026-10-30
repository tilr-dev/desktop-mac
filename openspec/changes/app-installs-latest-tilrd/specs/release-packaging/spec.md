## MODIFIED Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, verification and publication in CI, preserving the exact tested artifacts. Local development builds SHALL remain available without a local release publication command.

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the latest stable upstream server release without compilation or signing and builds both DMGs, and its publish job publishes those same files as an RC to beta after a release/X.Y push or to stable from the stable tag vX.Y.Z pushed by Dan using bin/release, without rebuilding them in the publish job
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

### Requirement: Verified upstream server artifacts
fetch_server.py SHALL acquire signed and notarized macOS tilrd and tilr from the same upstream GitHub Release, the latest stable tilrd release when it runs, independently from application releases, writing completion receipts only after verification of both executables. Nothing in the repository SHALL pin the server version.

#### Scenario: Acquire and verify pinned server artifacts
- **WHEN** the server is acquired for an application build
- **THEN** CI resolves the latest stable tilr-dev/tilrd GitHub Release, skipping release candidates, and acquires both architectures from that one release
- **AND** the release protocol is read from PROTOCOL_VERSION in the released tilr-proto source at the release tag and must equal TilrServerProtocolVersion in the application Info.plist
- **AND** tilr-v<version>-<target>.tar.gz from tilr-dev/tilrd has its published SHA-256 verified before extracting either executable
- **AND** both binaries have their architecture, Developer ID signature, expected Apple team, secure timestamp and matching version verified before completion
- **AND** a missing client, bad checksum, unsafe archive, unexpected architecture, signature, version or protocol stops acquisition without a completed receipt or source-build fallback
- **AND** an unavailable or invalid latest release or protocol stops acquisition instead of guessing a version
- **AND** no Rust, Zig, protoc, source checkout or Apple signing/notarization credentials are required
- **AND** fetch_server.py exits with code 1 on missing or invalid upstream assets
- **AND** the releases root records the selected version and protocol for bundling, without feed channels, app-build ranges or an artifact revision
- **AND** TILR_SERVER_RELEASE_ROOT may supply completed artifacts, which are verified before use
- **AND** application packaging copies both executables without compiling, stripping or re-signing either executable and without a bundled server manifest or bundled server version keys

#### Scenario: Verify inline code signing requirements
- **WHEN** an upstream macOS server is checked before import
- **THEN** codesign receives the inline Apple trust, Developer ID certificate and team requirement as one -R=<requirement> argument
- **AND** an invalid signature, unexpected team, missing Developer ID authority or missing secure timestamp stops acquisition

#### Scenario: Inspect the version in optimized upstream binaries
- **WHEN** Rust stores the upstream version/platform immediately after another string literal
- **THEN** acquisition recognizes the full version/platform without requiring a delimiter before the version
- **AND** a different full release number is rejected even when it contains the selected version as a suffix
