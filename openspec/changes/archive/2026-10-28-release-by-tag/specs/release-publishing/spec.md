## MODIFIED Requirements

### Requirement: Immutable publication with feed last
Local app publication SHALL target beta only; stable SHALL require the CI path from the stable tag vX.Y.Z pushed by Dan using bin/release, with no emergency flag or environment override. App publication SHALL validate completed receipts and exact artifacts, upload immutable downloads first and change feeds only after public verification.

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
- **THEN** it stops with an error explaining that stable requires the CI release from a pushed stable vX.Y.Z tag, before any CDN upload or feed change
- **AND** local beta publication retains its existing behavior

### Requirement: Release from CI
The Release workflow SHALL run automatically on pushes to release/** and stable vX.Y.Z tags (excluding v*-rc.*), use the pinned shared release workflow, and build, sign, notarize and publish both app architectures as release candidates to beta or stable releases from stable tags on GitHub-hosted macOS. Each key SHALL remain only in the job that uses it. Dan pushing the stable tag through bin/release SHALL be the release approval.

#### Scenario: Run a CI release
- **WHEN** a commit is pushed to release/X.Y and the shared workflow reports is_rc=true
- **THEN** the shared workflow provides version X.Y.Z-rc.N and a fresh tag vX.Y.Z-rc.N, where N increases for successive candidates
- **AND** the app job acquires the pinned tilrd GitHub Release for both architectures, verifies archive SHA-256 and expected Developer ID signature, and stops on failure without compiling or signing the server
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the app job resolves one build before packaging: the highest published build across stable and beta appcasts for both architectures plus one
- **AND** that build is logged and passed explicitly to both architecture builds and publication, without changing local release numbering
- **AND** the publish job publishes those artifacts to beta through the CI publish command without rebuilding or environment approval, holding the Sparkle and R2 keys but no Apple keys
- **AND** after successful CDN publication it attaches both unchanged DMGs to the shared GitHub prerelease and names it Tilr X.Y.Z-rc.N (<build>), using its existing body as Sparkle notes
- **AND** the shared workflow uses the release GitHub App token for candidate tags and GitHub Releases; only the publish job has contents: write on GITHUB_TOKEN, while the app job has only contents: read

#### Scenario: Run from a branch other than a release branch
- **WHEN** a commit is pushed to main or any branch outside release/**, or an RC tag is pushed
- **THEN** the Release workflow does not start and there is no workflow_dispatch entry point
- **AND** the apple-signing and release environments accept release/* branches and v* tags, without required reviewers

#### Scenario: Push the release tag
- **WHEN** Dan pushes stable tag vX.Y.Z using bin/release
- **THEN** the shared workflow verifies that its commit belongs to release/X.Y before creating or reusing the regular GitHub Release
- **AND** both lightweight and annotated tags are resolved to their commit before checkout verification
- **AND** a nonempty tag and is_rc=false select stable only for a stable tag push; both app and publish jobs check out that exact tag and verify its commit rather than building a branch tip
- **AND** both architectures are built, signed and notarized anew with a build greater than every published stable and beta build; the publish job uses those completed artifacts for stable appcasts
- **AND** after CDN publication both manifest-selected DMGs are attached to the regular GitHub Release titled Tilr X.Y.Z (<build>), preserving the generated GitHub Release notes and tag
- **AND** no stable publication runs without a nonempty shared tag and is_rc=false from a tag push

#### Scenario: Reject an unrelated stable tag
- **WHEN** a stable tag points outside the matching release/X.Y branch or that branch does not exist
- **THEN** the shared workflow fails before publication and neither app nor publish runs

#### Scenario: Resolve a build from channel appcasts
- **WHEN** the four stable/beta architecture appcasts contain different builds or multiple historical releases
- **THEN** numbering uses the highest build across every entry in all four appcasts
- **AND** a missing appcast contributes no builds, but network, HTTP errors other than missing feeds, malformed XML or invalid build values stop the run rather than guessing a number

#### Scenario: Protect an existing version tag
- **WHEN** artifacts are attached to the candidate prerelease
- **THEN** publication verifies that the existing candidate tag points to the checked-out commit and that the release is a prerelease before any CDN publication
- **AND** it never creates, moves or deletes that tag, replaces existing assets, or attaches candidate artifacts to a stable release

#### Scenario: Keep the marketing version numeric
- **WHEN** an RC is built with version X.Y.Z and RC number N
- **THEN** CFBundleShortVersionString and both DMG names use X.Y.Z without an RC suffix
- **AND** the RC suffix appears only in the Git tag and GitHub pre-release metadata

#### Scenario: Serialize candidate runs
- **WHEN** another release push arrives while an RC or stable build is active
- **THEN** the active run is not cancelled and the latest push replaces any pending run
- **AND** multiple pushes arriving faster than a release build are not supported
