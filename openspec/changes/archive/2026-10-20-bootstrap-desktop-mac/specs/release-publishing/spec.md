## ADDED Requirements

### Requirement: Credential preflight and secret handling
Release tools SHALL use existing authorized credentials without printing secrets, storing them in Git, creating replacement certificates to bypass restrictions or changing blanket key permissions.

#### Scenario: Check release access
- **WHEN** release_all.py --check --publish runs
- **THEN** it verifies required tools, configured identity/private key, notarization profile, Sparkle key, temporary real signing, disk-image creation and bucket access, without creating a release or publishing
- **WHEN** --check --publish-only runs
- **THEN** it checks publication using existing Sparkle/Cloudflare access without Apple signing private key, notarization login, compilation or image creation; publication still verifies signatures/staples and uses Sparkle/mounting tools
- **AND** macOS 14+ with Xcode, Python 3.11+, Node 22+/Wrangler and signing/notary access are prerequisites; ignored release.local.json contains identity/profile/public key only and environment overrides it
- **AND** all app architectures share the Sparkle public key, separate from Developer ID credentials; Cloudflare access uses the existing account/bucket with interactive login or a scoped runner secret
- **AND** scripts do not grant OS/tool permissions or bypass restrictions through UI automation/accounts/tools; unattended runners must already possess scoped access without interactive prompts

### Requirement: Immutable publication with feed last
App publication SHALL validate completed receipts and exact artifacts, upload immutable downloads first and change feeds only after public verification.

#### Scenario: Publish a pair
- **WHEN** release_all.py publishes or --publish-only is used
- **THEN** version/build/channel/key, hashes, signatures, stapling and feed metadata are checked; both appcasts are prepared/validated before either feed is changed
- **AND** stable feeds are /mac/<arch>/appcast.xml and beta feeds /mac/beta/<arch>/appcast.xml; each app reads only its built architecture/channel and a leftover TILR_UPDATE_FEED cannot override coordinator routing
- **AND** only HTTP 404 means an absent previous feed; other failures stop publication, and compatible feed history is retained
- **AND** immutable DMGs and checksum files are uploaded and fetched from the canonical CDN to verify bytes before appcast publication with configured cache control; existence checks use a unique query key and canonical cached-404 retries last at most 200 seconds, while checksum mismatches fail immediately
- **AND** normal releases preserve bundle ID, feed URLs and signing keys; key rotation is a separate migration, and correcting/reverting a bad public release requires a higher build
- **AND** a CDN rule overriding origin cache headers must exclude mac/**/appcast.xml before distribution; signed DMGs/bundles are never edited after appcast generation, and changed contents require rebuilding/signing/notarization
- **AND** --notes may embed release notes; a changed archive at an existing URL or an attempted downgrade/newer-feed overwrite is rejected
- **AND** failed builds publish neither architecture; serial feed writes are not atomic, require one release runner and are not coordinated across Macs by the local lock

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

### Requirement: Independent signed server publication
Server publication SHALL use Ed25519-signed JSON with explicit component/architecture/channel metadata, independently of Sparkle app publication.

#### Scenario: Publish a completed server
- **WHEN** release_server.py --publish-only runs
- **THEN** receipts/checksums and public immutable binaries are verified before the signed server feed is published last, preserving previous compatible releases
- **AND** a failed public check requires retrying identical publication rather than replacing a URL; architecture feed writes require one runner and are not atomic
- **AND** sign_update signs bytes only; no application DMG or Sparkle feed is published, and app publication never implicitly publishes a server feed

#### Scenario: Generate critical update items
- **WHEN** new appcast items are generated
- **THEN** generate_appcast receives --critical-update-version with an empty value, marking updates critical for every installed version
- **AND** resume leaves previously published feeds unchanged; dismissing the prompt does not mark the version skipped, and installation still requires consent

### Requirement: Application updater lifecycle and consent
Release apps SHALL retain the AppUpdates target/delegate and start Sparkle after the main window, with hourly checks, preferences and visible update attention.

#### Scenario: Present an update
- **WHEN** a newer app update is available
- **THEN** preferences expose automatic checks/download choices, banner and Dock attention/fallback indicate the offer, and notice clears appropriately; About does not show an update notice
- **AND** hosts with their own UNUserNotificationCenter delegate forward update notification callbacks; banner clicks and Check for Updates open Sparkle, denied notification permission uses its normal UI and submission errors also open it
- **AND** the hourly scheduler uses the last check time and saved preferences; macOS controls banner appearance/Focus and reminders clear on attention/session end
- **AND** critical updates omit Skip and Remind Later while retaining consent/dismissal rather than force-installing
- **AND** development, probe and --no-updates runs do not activate Sparkle
