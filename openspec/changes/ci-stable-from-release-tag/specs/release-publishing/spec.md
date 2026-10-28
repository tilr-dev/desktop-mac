## MODIFIED Requirements

### Requirement: Immutable publication with feed last
Local app publication SHALL target beta only; stable SHALL require the CI path from the stable tag created by merging the release PR, with no emergency flag or environment override. App publication SHALL validate completed receipts and exact artifacts, upload immutable downloads first and change feeds only after public verification.

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
- **THEN** it stops with an error explaining that stable requires the CI release from a merged release PR tag, before any CDN upload or feed change
- **AND** local beta publication retains its existing behavior

### Requirement: Release from CI
The Release workflow SHALL run automatically on pushes to release/**, use the pinned shared release-please and RC workflow, and build, sign, notarize and publish both app architectures as release candidates to beta or stable releases from stable tags on GitHub-hosted macOS. Each key SHALL remain only in the job that uses it. Merging the release PR SHALL be the only release approval.

#### Scenario: Run a CI release
- **WHEN** a commit is pushed to release/X.Y and the shared workflow reports is_rc=true
- **THEN** release-please opens or updates the release PR and the shared workflow provides numeric version X.Y.Z and a fresh tag vX.Y.Z-rc.N, where N increases for successive candidates
- **AND** the app job acquires the pinned tilrd GitHub Release for both architectures, verifies archive SHA-256 and expected Developer ID signature, and stops on failure without compiling or signing the server
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the app job resolves one build before packaging: the highest published build across stable and beta appcasts for both architectures plus one
- **AND** that build is logged and passed explicitly to both architecture builds and publication, without changing local release numbering
- **AND** the publish job publishes those artifacts to beta with --publish-only without environment approval, holding the Sparkle and R2 keys but no Apple keys
- **AND** after successful CDN publication it attaches both unchanged DMGs to the shared GitHub prerelease and names it Tilr X.Y.Z-rc.N (<build>), using its existing body as Sparkle notes
- **AND** the shared workflow uses the release GitHub App token for release PRs and tags; only the publish job has contents: write on GITHUB_TOKEN, while the app job has only contents: read

#### Scenario: Run from a branch other than a release branch
- **WHEN** a commit is pushed to main or any branch outside release/**, or a tag is pushed
- **THEN** the Release workflow does not start and there is no workflow_dispatch entry point
- **AND** the apple-signing and release environments accept only release/* branches, without required reviewers

#### Scenario: Merge the release PR
- **WHEN** the release-please PR is merged into release/X.Y
- **THEN** the shared workflow creates the stable tag vX.Y.Z without an environment approval
- **AND** release_created=true and is_rc=false select stable in the same workflow; both app and publish jobs check out that exact tag and verify its commit rather than building the event commit
- **AND** both architectures are built, signed and notarized anew with a build greater than every published stable and beta build; the publish job uses those completed artifacts for stable appcasts
- **AND** after CDN publication both manifest-selected DMGs are attached to the regular GitHub Release titled Tilr X.Y.Z (<build>), preserving the release-please body and tag
- **AND** no stable publication runs without the shared workflow reporting creation of the stable release

#### Scenario: Resolve a build from channel appcasts
- **WHEN** the four stable/beta architecture appcasts contain different builds or multiple historical releases
- **THEN** numbering uses the highest build across every entry in all four appcasts
- **AND** a missing appcast contributes no builds, but network, HTTP errors other than missing feeds, malformed XML or invalid build values stop the run rather than guessing a number

#### Scenario: Protect an existing version tag
- **WHEN** artifacts are attached to the candidate prerelease
- **THEN** publication verifies that the existing candidate tag points to the workflow commit and that the release is a prerelease before any CDN publication
- **AND** it never creates, moves or deletes that tag, replaces existing assets, or attaches candidate artifacts to a stable release

#### Scenario: Keep the marketing version numeric
- **WHEN** an RC is built with version X.Y.Z and RC number N
- **THEN** CFBundleShortVersionString and both DMG names use X.Y.Z without an RC suffix
- **AND** the RC suffix appears only in the Git tag and GitHub pre-release metadata

#### Scenario: Serialize release runs
- **WHEN** another release push arrives while an RC or stable build is active
- **THEN** the active run is not cancelled and the latest push replaces any pending run
- **AND** multiple pushes arriving faster than a release build are not supported

## ADDED Requirements

### Requirement: Stable publication preflight
Stable CI publication SHALL stop before any CDN upload, feed change or GitHub Release mutation if the stable release already has assets or the selected build is not newer than published builds. Both completed receipts SHALL be validated before any publication, and GitHub DMG paths SHALL come from their validated manifests.

#### Scenario: Stable release already published
- **WHEN** the stable GitHub Release already has DMGs or the selected build is not newer than a stable appcast entry
- **THEN** the run fails without changing CDN objects, appcasts, tags or the GitHub Release

#### Scenario: Invalid completed artifact
- **WHEN** either architecture has a missing, mismatched or tampered receipt or DMG
- **THEN** validation fails before any CDN upload or GitHub Release change, including when the second architecture fails
- **AND** each DMG path is read from release.json through publish.validate_manifest, including SHA-256 verification

#### Scenario: Verified stable pair
- **WHEN** both completed stable artifacts pass preflight
- **THEN** both feeds are prepared before publication and immutable downloads are uploaded and publicly verified before appcast.xml is changed and downloaded back for comparison
- **AND** the regular GitHub Release receives both unchanged DMGs after successful CDN publication, without prerelease conversion, tag creation or replacement assets
