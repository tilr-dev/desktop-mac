# release-packaging Specification

## Purpose
Define reproducible completed app/server artifacts, architecture-specific signing and separate setup/build/publication stages.

## Requirements

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

### Requirement: Architecture-specific signed artifacts
Public app releases SHALL contain two DMGs, arm64 and x86_64, sharing marketing version/build, with no universal packaging option.

#### Scenario: Build public artifacts
- **WHEN** release.py/release_all.py builds an architecture
- **THEN** each Mach-O, including all five Sparkle executables, is audited/thinned to that architecture, embedded code is signed inside-out with hardened runtime and secure timestamp, signatures are verified and app/DMG notarized and stapled
- **AND** public DMGs are named Tilr-<version>-<build>-<arch>.dmg and published at https://cdn.tilr.dev/mac/<arch>/Tilr-<version>-<build>-<arch>.dmg
- **AND** the DMG contains Tilr.app and an Applications link; user configuration and installed applications are untouched; there is no unsigned production fallback or App Sandbox requirement
- **AND** the verification public key and runtime-feed-selection marker are embedded in the signed bundle without a channel or SUFeedURL; for the same architecture/version/build/key, stable and beta packaging produce identical Info.plist bytes
- **AND** release.json is written only after completion and records identity/metadata and archive SHA-256; existing completed output is never overwritten
- **AND** AppIcon includes standard/retina sizes and Info.plist identifies it through CFBundleIconFile

### Requirement: Compact packaging evidence
Release packaging SHALL strip its newly built Swift/server executables before signing, retain diagnostic symbols outside shipped bundles, and record logical artifact sizes.

#### Scenario: Preserve diagnostics
- **WHEN** compact packaging runs
- **THEN** strip -x originals and an available Tilr.dSYM are retained in symbols, without promising source-level debug data absent compiler output; Sparkle exports are not stripped
- **AND** completed server artifacts are neither stripped nor re-signed when bundled
- **AND** app/server sizes.json records logical bytes excluding duplicate symlink targets, DMG bytes and Mach-O architectures, not filesystem allocation
- **AND** receipts marked packaging: 1 trigger architecture audits during verification/publication; existing releases stay byte-identical

### Requirement: Build switches and preview isolation
The release tools SHALL support explicit build inputs and ad-hoc previews without confusing them with publishable releases.

#### Scenario: Local preview or custom build
- **WHEN** --preview is selected
- **THEN** the DMG is named Tilr-<version>-<build>-<arch>-preview.dmg; artifacts are ad-hoc signed, not notarized, not publishable and lack an active updater
- **AND** --swift-disable-sandbox only changes SwiftPM build isolation, --build-package selects package input, --framework selects framework input and --skip-build consumes a successfully compiled matching executable immediately after that build; these do not bypass production signing/notarization requirements

### Requirement: Bounded timestamp signing retries
Signing SHALL retry timestamp-service failures on the same file according to release-packaging.json while retaining mandatory secure timestamps.

#### Scenario: Signing failure
- **WHEN** signing fails because Apple did not provide the required timestamp
- **THEN** codesign_attempts and codesign_retry_delay_seconds default to three attempts and five seconds, including Sparkle, server and preflight signing
- **AND** certificate/Keychain failures are not retried and exhaustion leaves incomplete artifacts for diagnosis/resume rather than weakening signing

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
