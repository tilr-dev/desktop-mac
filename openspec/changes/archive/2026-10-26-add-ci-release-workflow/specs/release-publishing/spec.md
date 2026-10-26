## MODIFIED Requirements

### Requirement: Credential preflight and secret handling
Release tools SHALL use existing authorized credentials without printing secrets, storing them in Git, creating replacement certificates to bypass restrictions or changing blanket key permissions.

#### Scenario: Check release access
- **WHEN** release_all.py --check --publish runs
- **THEN** it verifies required tools, configured identity/private key, notarization profile, Sparkle key, temporary real signing, disk-image creation and bucket access, without creating a release or publishing
- **WHEN** release_all.py --check runs without publication
- **THEN** it checks the build access without requiring the Sparkle private key
- **WHEN** --check --publish-only runs
- **THEN** it checks publication using existing Sparkle/Cloudflare access without Apple signing private key, notarization login, compilation or image creation; publication still verifies signatures/staples and uses Sparkle/mounting tools
- **AND** macOS 14+ with Xcode, Python 3.11+, Node 22+/Wrangler and signing/notary access are prerequisites; ignored release.local.json contains identity/profile/public key only and environment overrides it
- **AND** all app architectures share the Sparkle public key, separate from Developer ID credentials; Cloudflare access uses the existing account/bucket with interactive login or a scoped runner secret
- **AND** scripts do not grant OS/tool permissions or bypass restrictions through UI automation/accounts/tools; unattended runners must already possess scoped access without interactive prompts

#### Scenario: Sparkle key on an unattended runner
- **WHEN** TILR_SPARKLE_KEY_FILE names a Sparkle private key file
- **THEN** Sparkle signing and verification use that file instead of the Keychain account
- **AND** its public key, derived from the file, must equal the configured public key before publication

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

## ADDED Requirements

### Requirement: Release from CI
The Release workflow SHALL build, sign, notarize and publish both app architectures and the pinned server on GitHub-hosted macOS, run by hand from main, each key only in the job that uses it.

#### Scenario: Run a CI release
- **WHEN** Release runs with version, build and channel
- **THEN** the server job reuses the published pinned server after checking its feed checksum and Developer ID signature, or compiles it from the tilrd tag and then signs and notarizes it
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the publish job waits for approval in the release environment and publishes those artifacts with --publish-only, holding the Sparkle key and Cloudflare token but no Apple keys
