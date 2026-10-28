## MODIFIED Requirements

### Requirement: Release from CI
The Release workflow SHALL run automatically on pushes to release/**, use the pinned shared release-please and RC workflow, and build, sign, notarize and publish both app architectures as release candidates to beta on GitHub-hosted macOS. Each key SHALL remain only in the job that uses it. Merging the release PR SHALL be the only release approval.

#### Scenario: Push a release branch
- **WHEN** a commit is pushed to release/X.Y and the shared workflow reports is_rc=true
- **THEN** release-please opens or updates the release PR and the shared workflow provides numeric version X.Y.Z and a fresh tag vX.Y.Z-rc.N, where N increases for successive candidates
- **AND** the app job acquires the pinned tilrd GitHub Release for both architectures, verifies archive SHA-256 and expected Developer ID signature, and stops on failure without compiling or signing the server
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the app job resolves one build before packaging: the highest published build across stable and beta appcasts for both architectures plus one
- **AND** that build is logged and passed explicitly to both architecture builds and publication, without changing local release numbering
- **AND** the publish job publishes those artifacts to beta with --publish-only without environment approval, holding the Sparkle and R2 keys but no Apple keys
- **AND** after successful CDN publication it attaches both unchanged DMGs to the shared GitHub prerelease and names it Tilr X.Y.Z-rc.N (<build>), using its existing body as Sparkle notes
- **AND** the shared workflow uses the release GitHub App token for release PRs and tags; only the publish job has contents: write on GITHUB_TOKEN, while the app job has only contents: read

#### Scenario: Push another branch
- **WHEN** a commit is pushed to main or any branch outside release/**, or a tag is pushed
- **THEN** the Release workflow does not start and there is no workflow_dispatch entry point
- **AND** the apple-signing and release environments accept only release/* branches, without required reviewers

#### Scenario: Merge the release PR
- **WHEN** the release-please PR is merged into release/X.Y
- **THEN** the shared workflow creates the stable tag vX.Y.Z without an environment approval
- **AND** is_rc=false skips the candidate build and beta publication; stable artifact building and publication use the stable tag in a separate workflow

#### Scenario: Resolve a build from channel appcasts
- **WHEN** the four stable/beta architecture appcasts contain different builds or multiple historical releases
- **THEN** numbering uses the highest build across every entry in all four appcasts
- **AND** a missing appcast contributes no builds, but network, HTTP errors other than missing feeds, malformed XML or invalid build values stop the run rather than guessing a number

#### Scenario: Protect the shared candidate tag
- **WHEN** artifacts are attached to the candidate prerelease
- **THEN** publication verifies that the existing candidate tag points to the workflow commit and that the release is a prerelease before any CDN publication
- **AND** it never creates, moves or deletes that tag, replaces existing assets, or attaches candidate artifacts to a stable release

#### Scenario: Keep the marketing version numeric
- **WHEN** an RC is built with version X.Y.Z and RC number N
- **THEN** CFBundleShortVersionString and both DMG names use X.Y.Z without an RC suffix
- **AND** the RC suffix appears only in the Git tag and GitHub pre-release metadata
