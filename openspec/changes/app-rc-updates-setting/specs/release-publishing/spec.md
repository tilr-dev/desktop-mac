## MODIFIED Requirements

### Requirement: Immutable publication with feed last
App publication SHALL validate completed receipts and exact artifacts, upload immutable downloads first and change feeds only after public verification.

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
