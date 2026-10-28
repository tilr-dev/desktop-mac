## MODIFIED Requirements

### Requirement: Bounded verified app deltas
The app publisher SHALL generate at most maximum_deltas previous-source patches (default two, zero disables) without removing the full DMG fallback.

#### Scenario: Generate or omit patches
- **WHEN** retained completed DMGs match architecture, channel/feed and key and are referenced by the current feed
- **THEN** source checksums and feed EdDSA signatures are verified before Sparkle generates useful patches; absent suitable history produces full-only publication
- **AND** patches are kept in deltas, measured in delta-sizes.json, signed/verified, uploaded immutably and publicly downloaded/checksummed before feed changes, including resume verification
- **AND** a missing public patch or changed existing URL stops publication; architecture/channel histories never mix and the full DMG remains for installation/fallback

#### Scenario: Release runner without history
- **WHEN** the CI release publishes on a runner without retained completed DMGs
- **THEN** the publication is full-only

### Requirement: Independent signed server publication
Desktop release tools SHALL NOT publish an app-managed server feed or server update binaries. Server acquisition SHALL remain independent of Sparkle app publication.

#### Scenario: Publish a completed server
- **WHEN** the desktop release publishes application artifacts
- **THEN** only application downloads and Sparkle appcasts are published
- **AND** no server/macos feed or server binary is uploaded by desktop release tools
- **AND** release_server.py rejects the former --publish and --publish-only options before acquisition or publication

#### Scenario: Generate critical update items
- **WHEN** new appcast items are generated
- **THEN** generate_appcast receives --critical-update-version with an empty value, marking updates critical for every installed version
- **AND** resume leaves previously published feeds unchanged; dismissing the prompt does not mark the version skipped, and installation still requires consent
