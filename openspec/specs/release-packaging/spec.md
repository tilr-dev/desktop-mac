# release-packaging Specification

## Purpose
Define reproducible completed app/server artifacts, architecture-specific signing and separate setup/build/publication stages.

## Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, local verification and publication, preserving the exact tested artifacts.

#### Scenario: Default commands
- **WHEN** setup-release.command runs
- **THEN** it configures existing signing identity, pinned dependencies, Sparkle key and notarization, saving only non-secret settings to ignored release.local.json, without building or uploading
- **WHEN** release.command runs
- **THEN** it builds current app sources and acquires missing pinned signed/notarized servers from the upstream tilrd GitHub Release, reuses verified completed servers unchanged, produces both signed/notarized DMGs and publishes nothing
- **WHEN** upload.command runs
- **THEN** it selects the last successful pair from build/latest-app-release.json, prints version/build/channel and publishes beta without changing or rebuilding files; absent history requires explicit version/build
- **AND** a failed subsequent build does not change the pointer; explicit release_all.py --publish remains an opt-in combined shortcut for beta only

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the pinned upstream server without compilation or signing and builds both DMGs, and its publish job publishes those same files as an RC to beta after approval without rebuilding them

#### Scenario: Saved stable upload selection
- **WHEN** upload.command selects a completed pair whose saved publication channel is stable
- **THEN** it refuses before CDN uploads or feed changes and explains that stable requires promotion of a verified CI RC
- **AND** neither CLI flags nor environment variables bypass this restriction

#### Scenario: Build-only publication guidance
- **WHEN** release.command completes a stable build without publication
- **THEN** it reports the completed artifacts and explains that stable requires promotion of a verified CI RC, without suggesting a direct upload command
- **AND** a completed beta build still prints the upload command for the unchanged tested pair

### Requirement: Persistent release numbering
The release coordinator SHALL reserve monotonically increasing local builds under a lock without resetting on marketing-version changes.

#### Scenario: Inspect or reserve
- **WHEN** release.command --status runs
- **THEN** it reads source version, remembered release version, highest local/reserved build, next build, latest completed pair and pinned server without Keychain access, build reservation or CDN lookup
- **WHEN** a build passes access preflight
- **THEN** --version/--build/--channel select metadata, otherwise current version and next build apply; explicit builds exceed local failed/preview reservations, source Info.plist is unchanged and the chosen version is remembered on reservation
- **AND** rerunning after failure chooses a new number; explicit --resume reuses only matching completed verified artifacts, and incomplete output must be preserved/moved aside before retry
- **AND** build history must be retained and CDN numbers checked when changing machines; local numbering does not assert installed or public versions

#### Scenario: No release version in the template
- **WHEN** the source Info.plist contains `0.0.0-dev`
- **THEN** it is ignored as a release version; numeric release history or an explicit --version supplies the version
- **AND** without either, selection fails with `No release version yet; pass --version` without reserving a build
- **AND** --status and the automatic build preamble display the missing version without reserving or failing, so an explicit --version can initialize the first release

#### Scenario: CI release numbers
- **WHEN** the Release workflow runs on a runner without local history
- **THEN** it takes the explicit version and build, and publication refuses a build not newer than the published feed

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

### Requirement: Independently built server artifacts
release_server.py SHALL acquire signed and notarized macOS tilrd and tilr from the same pinned upstream GitHub Release independently from application releases, writing completion receipts only after verification of both executables.

#### Scenario: Build a server
- **WHEN** the pinned version is requested
- **THEN** both architectures are acquired by default, --arch selects one, --channel beta selects the independent beta feed and --min-app-build/--max-app-build constrain compatibility
- **AND** tilr-v<version>-<target>.tar.gz from tilr-dev/tilrd has its published SHA-256 verified before extracting either executable
- **AND** both binaries have their architecture, Developer ID signature, expected Apple team, secure timestamp and matching version verified before completion
- **AND** a missing client, bad checksum, unsafe archive, unexpected architecture, signature or version stops acquisition without a completed receipt or source-build fallback
- **AND** no Rust, Zig, protoc, source checkout or Apple signing/notarization credentials are required
- **AND** fetch_server.py exits with code 1 on missing or invalid upstream assets
- **AND** server-release.json pins the upstream version and protocol; completion metadata retains an independent feed build number
- **AND** TILR_SERVER_RELEASE_ROOT may supply completed artifacts, which are verified before use
- **AND** application packaging copies both executables and exact server manifest without compiling, stripping or re-signing either executable

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

#### Scenario: Verify inline code signing requirements
- **WHEN** an upstream macOS server is checked before import
- **THEN** codesign receives the inline Apple trust, Developer ID certificate and team requirement as one -R=<requirement> argument
- **AND** an invalid signature, unexpected team, missing Developer ID authority or missing secure timestamp stops acquisition

#### Scenario: Inspect the version in optimized upstream binaries
- **WHEN** Rust stores the upstream version/platform immediately after another string literal
- **THEN** acquisition recognizes the full version/platform without requiring a delimiter before the version
- **AND** a different full release number is rejected even when it contains the pinned version as a suffix
