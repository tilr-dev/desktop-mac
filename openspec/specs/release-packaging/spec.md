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
- **THEN** it builds current app sources and missing pinned server artifacts, reuses completed servers unchanged, produces both signed/notarized DMGs and publishes nothing
- **WHEN** upload.command runs
- **THEN** it selects the last successful pair from build/latest-app-release.json, prints version/build/channel and publishes without changing or rebuilding files; absent history requires explicit version/build
- **AND** a failed subsequent build does not change the pointer; explicit release_all.py --publish remains an opt-in combined shortcut

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** its build jobs produce the server and both DMGs, and its publish job publishes those same files after approval without rebuilding them

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
- **AND** build-time stable/beta feed and public key are embedded in the signed bundle; changing channel requires a new build/test
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
release_server.py SHALL build/sign/notarize servers independently from application releases, writing completion receipts before permitting publication or bundling.

#### Scenario: Build a server
- **WHEN** --version/--build are supplied
- **THEN** both architectures build by default, --arch selects one, --channel beta selects the independent beta feed and --min-app-build/--max-app-build constrain compatibility; protocol comes from server source
- **AND** output is build/server-releases/<version>-<build>-<arch> with a preview suffix for --preview; incomplete directories are not reused
- **AND** building servers requires Rust, Zig 0.15.2, protoc, Apple signing/notarization credentials and aarch64-apple-darwin/x86_64-apple-darwin Rust targets
- **AND** server-release.json pins the completed version/build/protocol; TILR_SERVER_RELEASE_ROOT may supply downloaded completed artifacts; public apps require public servers, preview apps may use matching preview artifacts if no public artifact exists
- **AND** application packaging copies exact server bytes/signature/manifest, without recompiling, renumbering or using universal server artifacts

### Requirement: One-command independent server release
The desktop repository SHALL provide a tagged-source server release command with credential-free preview. It SHALL validate the tagged protocol, preflight access, and build both signed and notarized macOS architectures. It SHALL show artifacts and require explicit confirmation before publishing, verify both channel feeds, and print the app pin. Failures SHALL stop later steps.

#### Scenario: Release tagged sources
- **WHEN** the command receives --version, --build, --min-app-build, and an exact existing --tag
- **THEN** it builds the detached tagged sources even when the source clone HEAD differs
- **AND** it runs release_all.py --check --publish with Homebrew Node 22 or newer before building both architectures

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
- **WHEN** the tag, protocol, Node version, preflight, build, or feed verification is invalid or fails
- **THEN** the command exits unsuccessfully without proceeding to later release steps
