## MODIFIED Requirements

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
