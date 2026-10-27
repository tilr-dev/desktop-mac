# release-publishing Specification

## Purpose
Define verified immutable app/server publication, update compatibility, delta generation and application update consent.

## Requirements

### Requirement: Credential preflight and secret handling
Release tools SHALL use existing authorized credentials without printing secrets, storing them in Git, creating replacement certificates to bypass restrictions or changing blanket key permissions.

#### Scenario: Check release access
- **WHEN** release_all.py --check --publish runs
- **THEN** it verifies required tools, configured identity/private key, notarization profile, Sparkle key, temporary real signing, disk-image creation and bucket access, without creating a release or publishing
- **WHEN** release_all.py --check runs without publication
- **THEN** it checks the build access without requiring the Sparkle private key
- **WHEN** --check --publish-only runs
- **THEN** it checks publication using existing Sparkle/R2 access without Apple signing private key, notarization login, compilation or image creation; publication still verifies signatures/staples and uses Sparkle/mounting tools
- **AND** macOS 14+ with Xcode, Python 3.11+, the AWS CLI and signing/notary access are prerequisites; ignored release.local.json contains identity/profile/public key only and environment overrides it
- **AND** all app architectures share the Sparkle public key, separate from Developer ID credentials; CDN access uses R2 S3 keys for the existing account/bucket through the AWS CLI, from a local profile or a scoped runner secret
- **AND** scripts do not grant OS/tool permissions or bypass restrictions through UI automation/accounts/tools; unattended runners must already possess scoped access without interactive prompts

#### Scenario: Sparkle key on an unattended runner
- **WHEN** TILR_SPARKLE_KEY_FILE names a Sparkle private key file
- **THEN** Sparkle signing and verification use that file instead of the Keychain account
- **AND** its public key, derived from the file, must equal the configured public key before publication

### Requirement: Immutable publication with feed last
Direct app publication SHALL target beta only; stable SHALL require promotion of a verified CI release candidate, with no emergency flag or environment override. App publication SHALL validate completed receipts and exact artifacts, upload immutable downloads first and change feeds only after public verification.

#### Scenario: Publish a pair
- **WHEN** release_all.py publishes or --publish-only is used
- **THEN** version/build/channel/key, hashes, signatures, stapling and feed metadata are checked; both appcasts are prepared/validated before either feed is changed
- **AND** the public host is https://cdn.tilr.dev; stable feeds are https://cdn.tilr.dev/mac/<arch>/appcast.xml and beta feeds https://cdn.tilr.dev/mac/beta/<arch>/appcast.xml, where <arch> is arm64 or x86_64; each app reads only its compiled architecture’s feed, selecting stable by default or beta when Receive RC versions is enabled; a leftover TILR_UPDATE_FEED cannot override application selection or coordinator routing
- **AND** only HTTP 404 means an absent previous feed; other failures stop publication, and compatible feed history is retained
- **AND** immutable DMGs and checksum files are uploaded and fetched from the canonical CDN to verify bytes before appcast.xml is published last with Cache-Control: no-cache, max-age=0, must-revalidate; existence checks use a unique query key and canonical cached-404 retries last at most 200 seconds, while checksum mismatches fail immediately
- **AND** the published feed is downloaded back and compared byte-for-byte with the prepared feed; a mismatch fails publication, published.json records successful publication, and appcast.xml is saved beside the local release for inspection
- **AND** normal releases preserve bundle ID, feed URLs and signing keys; key rotation is a separate migration, and correcting/reverting a bad public release requires a higher build
- **AND** a CDN rule overriding origin cache headers must exclude mac/**/appcast.xml before distribution; signed DMGs/bundles are never edited after appcast generation, and changed contents require rebuilding/signing/notarization
- **AND** --notes may embed release notes; a changed archive at an existing URL or an attempted downgrade/newer-feed overwrite is rejected
- **AND** failed builds publish neither architecture; serial feed writes are not atomic, require one release runner and are not coordinated across Macs by the local lock

#### Scenario: Reject direct stable publication
- **WHEN** release_all.py --publish or --publish-only selects stable, explicitly or through build/latest-app-release.json (including upload.command)
- **THEN** it stops with an error explaining that stable requires promotion of a verified CI RC, before any CDN upload or feed change
- **AND** local beta publication retains its existing behavior

### Requirement: Verified resume and downloads evidence
Publication SHALL resume idempotently only from completed artifacts matching the requested metadata and publicly verified bytes.

#### Scenario: Partial publication
- **WHEN** --resume or the same explicit upload is retried
- **THEN** matching completed artifacts and their hashes are reused without rebuilding/signing/notarizing; already-published builds require matching feed signatures/metadata and an exact downloaded DMG
- **AND** completion is reported only after both feeds verify and build/releases/<version>-<build>-<channel>-downloads.json contains both immutable URLs
- **AND** website code/deployment is unchanged; download buttons use verified URLs for both architectures with an About This Mac hint, never proposed URLs presented as live

### Requirement: Bounded verified app deltas
The app publisher SHALL generate at most maximum_deltas previous-source patches (default two, zero disables) without removing the full DMG fallback.

#### Scenario: Generate or omit patches
- **WHEN** retained completed DMGs match architecture, channel/feed and key and are referenced by the current feed
- **THEN** source checksums and feed EdDSA signatures are verified before Sparkle generates useful patches; absent suitable history produces full-only publication
- **AND** patches are kept in deltas, measured in delta-sizes.json, signed/verified, uploaded immutably and publicly downloaded/checksummed before feed changes, including resume verification
- **AND** a missing public patch or changed existing URL stops publication; architecture/channel histories never mix and the full DMG remains for installation/fallback
- **AND** server updates continue to download full binaries

#### Scenario: Release runner without history
- **WHEN** the CI release publishes on a runner without retained completed DMGs
- **THEN** the publication is full-only

### Requirement: Independent signed server publication
Server publication SHALL use Ed25519-signed JSON with explicit component/architecture/channel metadata, independently of Sparkle app publication. The current contract shares the existing app release Ed25519 key with server feeds, verified at runtime using CryptoKit and the public key embedded in the signed app bundle.

#### Scenario: Publish a completed server
- **WHEN** release_server.py --publish-only runs
- **THEN** server feeds use https://cdn.tilr.dev/server/macos/<arch>/<stable|beta>.json for arm64 or x86_64; receipts/checksums and public immutable binaries are verified before the signed server feed is published last, preserving previous compatible releases
- **AND** a failed public check requires retrying identical publication rather than replacing a URL; architecture feed writes require one runner and are not atomic
- **AND** sign_update signs bytes only; no application DMG or Sparkle feed is published, and app publication never implicitly publishes a server feed

#### Scenario: Generate critical update items
- **WHEN** new appcast items are generated
- **THEN** generate_appcast receives --critical-update-version with an empty value, marking updates critical for every installed version
- **AND** resume leaves previously published feeds unchanged; dismissing the prompt does not mark the version skipped, and installation still requires consent

### Requirement: Application updater lifecycle and consent
Release apps SHALL use Sparkle pinned to 2.10.0 in Package.swift/Package.resolved and SPUStandardUpdaterController with the native “Check for Updates…” menu, retain the AppUpdates target/delegate and start Sparkle after the main window, with hourly checks, preferences and visible update attention.

#### Scenario: Present an update
- **WHEN** a newer app update is available
- **THEN** preferences expose automatic checks/download choices, banner and Dock attention/fallback indicate the offer, and notice clears appropriately; About does not show an update notice
- **AND** hosts with their own UNUserNotificationCenter delegate forward update notification callbacks; banner clicks and Check for Updates open Sparkle, denied notification permission uses its normal UI and submission errors also open it
- **AND** the hourly scheduler uses the last check time and saved preferences; macOS controls banner appearance/Focus and reminders clear on attention/session end
- **AND** critical updates omit Skip and Remind Later while retaining consent/dismissal rather than force-installing
- **AND** development, probe and --no-updates runs do not activate Sparkle

#### Scenario: Select RC updates at runtime
- **WHEN** a release app checks for updates with Receive RC versions disabled
- **THEN** Sparkle uses https://cdn.tilr.dev/mac/<arch>/appcast.xml for its compiled arm64 or x86_64 architecture, regardless of TILR_UPDATE_FEED
- **WHEN** the user enables Receive RC versions in Update Settings
- **THEN** the next check uses https://cdn.tilr.dev/mac/beta/<arch>/appcast.xml without editing or re-signing the bundle
- **AND** the setting defaults to off, persists between launches and can be switched back to stable for the next check
- **AND** changing the setting does not interrupt a check already in progress
- **AND** Update Settings also exposes Sparkle’s saved automatic checks/download choices

#### Scenario: Switch after a deferred offer
- **WHEN** Sparkle has retained an update offer from the previous feed and the user changes Receive RC versions
- **THEN** the next check uses the newly selected feed instead of resuming the previous feed’s cached offer
- **AND** an active session completes before the updater is replaced, preserving automatic-check/download preferences and functional menu, About and settings controls

#### Scenario: Switch after an automatic installation is prepared
- **WHEN** Sparkle has already prepared an automatic RC installation and the user disables Receive RC versions
- **THEN** the prepared installation is kept and can be installed
- **AND** subsequent fresh appcast checks use the stable feed; switching the preference does not cancel the prepared installer

### Requirement: Release from CI
The Release workflow SHALL build, sign, notarize and publish both app architectures and acquire the pinned signed/notarized upstream server on GitHub-hosted macOS, publish only release candidates to beta, run by hand from a release/X.Y branch, each key only in the job that uses it.

#### Scenario: Run a CI release
- **WHEN** Release runs with numeric marketing version X.Y.Z, a positive RC number N and an optional build (without a channel input)
- **THEN** the app job acquires the pinned tilrd GitHub Release for both architectures, verifies the archive SHA-256 and expected Developer ID signature, and stops on failure without compiling or signing the server
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the publish job waits for approval in the release environment and publishes those artifacts to beta with --publish-only, holding the Sparkle key and the R2 keys but no Apple keys
- **AND** the app job resolves one build before packaging: the highest published build across stable and beta appcasts for both architectures plus one when the build input is empty, or the explicit build after checking it exceeds that maximum
- **AND** that build is logged and passed explicitly to both architecture builds and publication, without changing local release numbering
- **AND** after successful CDN publication the publish job creates tag vX.Y.Z-rc.N on the workflow commit and a GitHub pre-release (--prerelease) named Tilr X.Y.Z-rc.N (<build>), with both unchanged DMGs from the app artifact and the notes input
- **AND** only the publish job has contents: write; the workflow commits no repository changes

#### Scenario: Run from a branch other than a release branch
- **WHEN** Release is started from main, a task branch or a tag
- **THEN** a first job without keys or environment fails naming the ref, and no job holding keys starts
- **AND** the apple-signing and release environments accept only release/* branches, so a job with keys cannot run from another ref either

#### Scenario: Resolve a build from channel appcasts
- **WHEN** the four stable/beta architecture appcasts contain different builds or multiple historical releases
- **THEN** numbering uses the highest build across every entry in all four appcasts
- **AND** a missing appcast contributes no builds, but network, HTTP errors other than missing feeds, malformed XML or invalid build values stop the run rather than guessing a number
- **AND** an explicit build not greater than the published maximum is rejected

#### Scenario: Protect an existing version tag
- **WHEN** vX.Y.Z-rc.N already exists during GitHub publication
- **THEN** the run stops with a clear error without updating or deleting the tag or changing an existing GitHub Release

#### Scenario: Keep the marketing version numeric
- **WHEN** an RC is built with version X.Y.Z and RC number N
- **THEN** CFBundleShortVersionString and both DMG names use X.Y.Z without an RC suffix
- **AND** the RC suffix appears only in the Git tag and GitHub pre-release metadata
