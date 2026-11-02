## MODIFIED Requirements

### Requirement: Stable publication preflight
Stable CI publication SHALL stop before any CDN upload, feed change or GitHub Release mutation if the stable release already has assets or the selected build is older than a published build or conflicts with the bytes already published for that build. The same build with the same verified bytes SHALL be resumable after partial publication. Both completed receipts SHALL be validated before any publication, and GitHub DMG paths SHALL come from their validated manifests.

#### Scenario: Stable release already published
- **WHEN** the stable GitHub Release already has DMGs or the selected build is older than a published appcast entry or has different bytes at an existing immutable download URL
- **THEN** the run fails without changing CDN objects, appcasts, tags or the GitHub Release

#### Scenario: Invalid completed artifact
- **WHEN** either architecture has a missing, mismatched or tampered receipt or DMG
- **THEN** validation fails before any CDN upload or GitHub Release change, including when the second architecture fails
- **AND** each DMG path is read from release.json through publish.validate_manifest, including SHA-256 verification

#### Scenario: Verified stable pair
- **WHEN** both completed stable artifacts pass preflight
- **THEN** both feeds are prepared before publication and immutable downloads are uploaded and publicly verified before appcast.xml is changed and downloaded back for comparison
- **AND** the regular GitHub Release receives both unchanged DMGs after successful CDN publication, without prerelease conversion, tag creation or replacement assets

#### Scenario: Resume partial stable publication
- **WHEN** publication fails between architectures or after CDN publication before GitHub DMG upload
- **AND** the publish job is repeated using the same completed build and identical bytes while the GitHub Release has no assets
- **THEN** publication verifies and preserves existing immutable downloads and matching appcasts, completes any missing architecture and attaches both unchanged DMGs to the GitHub Release
- **AND** a newer published build or conflicting bytes stops the repeated job before any CDN, appcast or GitHub Release mutation

