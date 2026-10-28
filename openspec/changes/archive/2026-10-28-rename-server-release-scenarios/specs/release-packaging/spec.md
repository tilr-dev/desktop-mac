## REMOVED Requirements

### Requirement: Independently built server artifacts
**Reason**: The requirement name and the scenario title refer to building the server, while the requirement acquires and verifies signed upstream artifacts.
**Migration**: Replaced by "Verified upstream server artifacts" in ADDED Requirements below, with the same behavior.

### Requirement: One-command independent server release
**Reason**: The requirement name and scenario titles refer to source builds and publication, while the command acquires and verifies an upstream release; the scenario about rejecting a removed source option describes no current product behavior.
**Migration**: Replaced by "One-command upstream server acquisition" in ADDED Requirements below; acquisition without a local checkout remains covered by its own scenario.

## ADDED Requirements

### Requirement: Verified upstream server artifacts
release_server.py SHALL acquire signed and notarized macOS tilrd and tilr from the same pinned upstream GitHub Release independently from application releases, writing completion receipts only after verification of both executables.

#### Scenario: Acquire and verify pinned server artifacts
- **WHEN** the pinned version is requested
- **THEN** both architectures are acquired by default and --arch selects one
- **AND** tilr-v<version>-<target>.tar.gz from tilr-dev/tilrd has its published SHA-256 verified before extracting either executable
- **AND** both binaries have their architecture, Developer ID signature, expected Apple team, secure timestamp and matching version verified before completion
- **AND** a missing client, bad checksum, unsafe archive, unexpected architecture, signature or version stops acquisition without a completed receipt or source-build fallback
- **AND** no Rust, Zig, protoc, source checkout or Apple signing/notarization credentials are required
- **AND** fetch_server.py exits with code 1 on missing or invalid upstream assets
- **AND** server-release.json pins the upstream version and protocol; completion metadata retains the pinned artifact revision for bundling without feed channels or configurable app-build ranges
- **AND** TILR_SERVER_RELEASE_ROOT may supply completed artifacts, which are verified before use
- **AND** application packaging copies both executables and exact server manifest without compiling, stripping or re-signing either executable

### Requirement: One-command upstream server acquisition
The desktop repository SHALL provide a command to acquire and verify an upstream server release, inspect its artifacts and print the application pin. It SHALL retain upstream signatures and SHALL NOT publish an app-managed server feed. Failures SHALL stop later steps.

#### Scenario: Acquire and verify an exact upstream release
- **WHEN** the command receives a release version and protocol version
- **THEN** it acquires and verifies both signed macOS architectures from that exact upstream GitHub Release without selecting or building source checkouts

#### Scenario: Acquire artifacts without a local checkout
- **WHEN** the operator runs release_server.py without a source option
- **THEN** it acquires the exact --version from the upstream GitHub Release using the supplied --protocol-version
- **AND** no local source checkout is read or built

#### Scenario: Inspect verified release artifacts
- **WHEN** the verified artifacts are ready
- **THEN** the command displays release.json and the upstream server version
- **AND** no publication step or confirmation prompt follows inspection

#### Scenario: Print the application pin
- **WHEN** acquisition and verification of both architectures completes
- **THEN** the command prints the upstream version and protocolVersion as a JSON app pin
- **AND** the former publication confirmation is absent and no server feed or binary is uploaded

#### Scenario: Reject obsolete feed options
- **WHEN** either server release command receives publication, feed channel, app-build range options
- **THEN** argument validation rejects them before acquisition or publication

#### Scenario: Credential-free preview
- **WHEN** the operator selects --preview
- **THEN** the command shows the acquisition plan and pin
- **AND** it does not require credentials, download, build, sign, notarize, or publish

#### Scenario: Invalid input or failed step
- **WHEN** release input, acquisition, or verification fails
- **THEN** the command exits unsuccessfully without proceeding to later release steps

#### Scenario: Verify inline code signing requirements
- **WHEN** an upstream macOS server is checked before import
- **THEN** codesign receives the inline Apple trust, Developer ID certificate and team requirement as one -R=<requirement> argument
- **AND** an invalid signature, unexpected team, missing Developer ID authority or missing secure timestamp stops acquisition

#### Scenario: Inspect the version in optimized upstream binaries
- **WHEN** Rust stores the upstream version/platform immediately after another string literal
- **THEN** acquisition recognizes the full version/platform without requiring a delimiter before the version
- **AND** a different full release number is rejected even when it contains the pinned version as a suffix
