## MODIFIED Requirements

### Requirement: Release from CI
The Release workflow SHALL run automatically on pushes to release/** and stable vX.Y.Z tags (excluding v*-rc.*), use the pinned shared release workflow, and build, sign, notarize and publish both app architectures as release candidates to beta or stable releases from stable tags on GitHub-hosted macOS. Each key SHALL remain only in the job that uses it. Dan pushing the stable tag through bin/release SHALL be the release approval.

#### Scenario: Run a CI release
- **WHEN** a commit is pushed to release/X.Y and the shared workflow reports is_rc=true
- **THEN** the shared workflow provides version X.Y.Z-rc.N and a fresh tag vX.Y.Z-rc.N, where N increases for successive candidates
- **AND** the app job acquires the latest stable tilrd GitHub Release for both architectures, verifies archive SHA-256 and expected Developer ID signature, and stops on failure without compiling or signing the server
- **AND** the app job installs the gitpm release pinned in gitpm.pin as the plugin manager before compiling, without gitpm sources or a Rust toolchain, and stops on any verification failure
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the app job resolves one build before packaging: the highest published build across stable and beta appcasts for both architectures plus one
- **AND** that build is logged and passed explicitly to both architecture builds and publication, without local release history or reservations
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
- **AND** the app job installs the gitpm release pinned in gitpm.pin at that tag, as for candidates
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
- **AND** the full version from the tag, including any RC suffix, is preserved separately in the bundle TilrReleaseTag and appcast item title; Sparkle shortVersionString remains numeric

#### Scenario: Serialize candidate runs
- **WHEN** another release push arrives while an RC or stable build is active
- **THEN** the active run is not cancelled and the latest push replaces any pending run
- **AND** multiple pushes arriving faster than a release build are not supported


## ADDED Requirements

### Requirement: Release identity in the update panel
The About / Check for Updates panel SHALL show the full tagged version for installed and available releases independently of Sparkle's numeric version and build comparison.

#### Scenario: Display a release candidate
- **WHEN** a release built from vX.Y.Z-rc.N is installed or offered by the beta appcast
- **THEN** Installed or Available respectively shows X.Y.Z-rc.N (build B)
- **AND** Installed reads TilrReleaseTag from the signed bundle and Available reads the appcast title Tilr X.Y.Z-rc.N
- **AND** packaging derives this metadata from the tag rather than the selected update channel

#### Scenario: Display a stable or older release
- **WHEN** a stable vX.Y.Z release is installed or offered
- **THEN** the panel shows X.Y.Z (build B), without an RC suffix
- **WHEN** the bundle lacks TilrReleaseTag or the appcast lacks a recognized release title
- **THEN** the panel falls back to CFBundleShortVersionString or sparkle:shortVersionString respectively

#### Scenario: Compare builds independently of release display
- **WHEN** an installed X.Y.Z-rc.N at build B checks a stable X.Y.Z at a greater build
- **THEN** Sparkle offers the stable build as an update
- **WHEN** no newer build is available
- **THEN** the panel retains the up-to-date status while displaying the full available version
- **AND** CFBundleShortVersionString, CFBundleVersion, DMG naming and Sparkle comparison fields retain their existing numeric formats

#### Scenario: Carry verified tag identity through packaging and publication
- **WHEN** CI verifies a stable or RC tag
- **THEN** its full version without the leading v is passed with --release-tag through release_all.py to release.py and stored in the completed release receipt
- **AND** omitted --release-tag defaults to the numeric version; an explicit value must match that version with an optional positive -rc.N suffix
- **WHEN** a resumed build or publication requests a different release tag from its completed artifact
- **THEN** it stops before publishing that artifact
- **AND** publication verifies that the bundle release tag and generated appcast title match the receipt
