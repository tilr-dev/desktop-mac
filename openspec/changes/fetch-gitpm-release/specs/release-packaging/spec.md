## ADDED Requirements

### Requirement: Pinned plugin manager release
CI and release builds SHALL link the plugin manager from the gitpm GitHub Release named in gitpm.pin, never from gitpm sources. gitpm.pin SHALL name the release tag, the full commit that tag points to and the SHA-256 of the release's universal Apple archive.

#### Scenario: Install the pinned release
- **WHEN** scripts/fetch_gitpm.py runs
- **THEN** it downloads gitpm-ffi-<tag>-universal-apple-darwin.tar.gz and its .sha256 file from the pinned tilr-dev/gitpm release
- **AND** it accepts the archive only when its SHA-256 equals both the pinned value and the published checksum and the tag resolves to the pinned commit
- **AND** it accepts only regular files and directories under the archive's single top folder, which must contain GitpmFFI.xcframework with a static library holding arm64 and x86_64 slices and swift/Gitpm.swift
- **AND** it installs Vendor/GitpmFFI.xcframework and Sources/Gitpm/Generated/Gitpm.swift, recording the pinned release so scripts/build-gitpm.sh keeps it when no gitpm sources are present

#### Scenario: Reject an unverified release
- **WHEN** the pin is malformed, an asset is missing, a checksum differs, the tag points elsewhere, the archive has an unsafe or missing entry or a slice is missing
- **THEN** the fetch fails with the reason and leaves any previously installed plugin manager unchanged

#### Scenario: Reuse an installed release
- **WHEN** the pinned release is already installed and its files are present
- **THEN** the fetch succeeds without downloading

#### Scenario: Preserve the installed release on an installation error
- **WHEN** staging or replacing the verified library, Swift API or release stamp fails
- **THEN** the fetch fails with the reason and restores any previously installed library, Swift API and stamp

#### Scenario: Change the gitpm version
- **WHEN** the application needs another plugin manager version
- **THEN** a developer updates gitpm.pin and any Swift code using the plugin manager API in the same change; there is no automatic pin bump

## MODIFIED Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, verification and publication in CI, preserving the exact tested artifacts. Local development builds SHALL remain available without a local release publication command.

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the latest stable upstream server release without compilation or signing, installs the pinned gitpm release without compiling it, and builds both DMGs, and its publish job publishes those same files as an RC to beta after a release/X.Y push or to stable from the stable tag vX.Y.Z pushed by Dan using bin/release, without rebuilding them in the publish job
- **AND** release_all.py packages explicit CI version/build inputs without publication, local build reservations or a saved last-release selection

#### Scenario: Default commands
- **WHEN** the CI build job invokes release_all.py
- **THEN** explicit version/build/channel inputs package both architectures without publishing; CI provisions credentials separately

#### Scenario: Saved stable upload selection
- **WHEN** the CI publisher selects stable
- **THEN** it uses the verified workflow tag and explicit metadata rather than a saved local upload selection

#### Scenario: Build-only publication guidance
- **WHEN** packaging completes
- **THEN** it reports the completed artifact directories without suggesting a local upload command

#### Scenario: Local development
- **WHEN** a developer builds or tests locally
- **THEN** run.sh and the artifact verifier remain available without configuring a local release workflow

