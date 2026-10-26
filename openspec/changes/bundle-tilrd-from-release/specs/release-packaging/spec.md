## MODIFIED Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, local verification and publication, preserving the exact tested artifacts.

#### Scenario: Default commands
- **WHEN** setup-release.command runs
- **THEN** it configures existing signing identity, pinned dependencies, Sparkle key and notarization, saving only non-secret settings to ignored release.local.json, without building or uploading
- **WHEN** release.command runs
- **THEN** it builds current app sources and acquires missing pinned signed/notarized servers from the upstream tilrd GitHub Release, reuses verified completed servers unchanged, produces both signed/notarized DMGs and publishes nothing
- **WHEN** upload.command runs
- **THEN** it selects the last successful pair from build/latest-app-release.json, prints version/build/channel and publishes without changing or rebuilding files; absent history requires explicit version/build
- **AND** a failed subsequent build does not change the pointer; explicit release_all.py --publish remains an opt-in combined shortcut

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the pinned upstream server without compilation or signing and builds both DMGs, and its publish job publishes those same files after approval without rebuilding them

### Requirement: Independently built server artifacts
release_server.py SHALL acquire signed and notarized macOS servers from the pinned tilrd GitHub Release independently from application releases, writing completion receipts only after verification.

#### Scenario: Build a server
- **WHEN** the pinned version is requested
- **THEN** both architectures are acquired by default, --arch selects one, --channel beta selects the independent beta feed and --min-app-build/--max-app-build constrain compatibility
- **AND** the archive is tilr-v<version>-<target>.tar.gz from tilr-dev/tilrd and its published SHA-256 is verified before extracting executable bytes
- **AND** each server's architecture and Developer ID signature are verified, including the expected Apple team, before its embedded release version/platform is inspected; the native binary is also executed to check its version
- **AND** a missing release, bad checksum, unsafe archive, unexpected architecture, signature or version stops acquisition without a completed receipt or a source-build fallback
- **AND** no Rust, Zig, protoc, source checkout or Apple signing/notarization credentials are required to acquire the server
- **AND** fetch_server.py exits with code 1 on missing or invalid upstream assets, replacing its former exit code 3 for an unpublished feed build
- **AND** server-release.json pins the upstream version and protocol; completion metadata retains an independent feed build number for compatibility with the existing app updater
- **AND** TILR_SERVER_RELEASE_ROOT may supply completed artifacts, which are verified before use
- **AND** application packaging copies exact server bytes/signature/manifest, without compiling, stripping or re-signing them

### Requirement: One-command independent server release
The desktop repository SHALL provide a command to acquire an upstream server release and optionally publish its independent app-managed feed. It SHALL retain the upstream signatures and show artifacts before requiring explicit publication confirmation. Failures SHALL stop later steps.

#### Scenario: Release tagged sources
- **WHEN** the command receives a release version and feed compatibility metadata
- **THEN** it acquires and verifies both signed macOS architectures from that exact upstream GitHub Release without selecting or building source checkouts

#### Scenario: Select sources for a lower-level build
- **WHEN** the operator supplies the former --source PATH option to release_server.py
- **THEN** argument validation rejects it without building, signing or publishing anything
- **AND** --version selects the upstream GitHub Release instead

#### Scenario: Default sources for a lower-level build
- **WHEN** the operator runs release_server.py without a source option
- **THEN** it acquires the exact --version from the upstream GitHub Release using the supplied --protocol-version
- **AND** no local source checkout is read or built

#### Scenario: Inspect before publishing
- **WHEN** the verified artifacts are ready
- **THEN** the command displays release.json and the upstream server version
- **AND** no publication occurs unless the operator explicitly confirms
- **AND** refusal or end of input leaves the artifacts available for inspection

#### Scenario: Confirm publication
- **WHEN** the operator confirms publication
- **THEN** the command publishes the prepared artifacts and verifies both channel feeds
- **AND** it prints the upstream version and protocolVersion as a JSON app pin

#### Scenario: Credential-free preview
- **WHEN** the operator selects --preview
- **THEN** the command shows the acquisition and publication plan and pin
- **AND** it does not require credentials, download, build, sign, notarize, or publish

#### Scenario: Invalid input or failed step
- **WHEN** release input, acquisition, verification, or publication fails
- **THEN** the command exits unsuccessfully without proceeding to later release steps
