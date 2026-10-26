## MODIFIED Requirements

### Requirement: Release from CI
The Release workflow SHALL build, sign, notarize and publish both app architectures and acquire the pinned signed/notarized upstream server on GitHub-hosted macOS, run by hand from main, each key only in the job that uses it.

#### Scenario: Run a CI release
- **WHEN** Release runs with version, channel and an optional build
- **THEN** the app job acquires the pinned tilrd GitHub Release for both architectures, verifies the archive SHA-256 and expected Developer ID signature, and stops on failure without compiling or signing the server
- **AND** the app job compiles both architectures, then signs, notarizes and packages them with Apple keys in a temporary keychain removed in every outcome
- **AND** the publish job waits for approval in the release environment and publishes those artifacts with --publish-only, holding the Sparkle key and the R2 keys but no Apple keys
- **AND** the app job resolves one build before packaging: the highest published build across both architecture appcasts of that channel plus one when the build input is empty, or the explicit build after checking it exceeds that maximum
- **AND** that build is logged and passed explicitly to both architecture builds and publication, without changing local release numbering
- **AND** after successful CDN publication the publish job creates tag v<version> on the workflow commit and a GitHub Release named Tilr <version> (<build>), with both unchanged DMGs from the app artifact and the notes input
- **AND** only the publish job has contents: write; the workflow commits no repository changes

#### Scenario: Resolve a build from channel appcasts
- **WHEN** the two architecture appcasts contain different builds or multiple historical releases
- **THEN** numbering uses the highest build across every entry in both appcasts of the selected channel
- **AND** a missing appcast contributes no builds, but network, HTTP errors other than missing feeds, malformed XML or invalid build values stop the run rather than guessing a number
- **AND** an explicit build not greater than the published maximum is rejected

#### Scenario: Protect an existing version tag
- **WHEN** v<version> already exists during GitHub publication
- **THEN** the run stops with a clear error without updating or deleting the tag or changing an existing GitHub Release
