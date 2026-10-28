## MODIFIED Requirements

### Requirement: Separate setup build and publication
The release workflow SHALL separate credential setup, building, local verification and publication, preserving the exact tested artifacts.

#### Scenario: Default commands
- **WHEN** setup-release.command runs
- **THEN** it configures existing signing identity, pinned dependencies, Sparkle key and notarization, saving only non-secret settings to ignored release.local.json, without building or uploading
- **WHEN** release.command runs
- **THEN** it builds current app sources and acquires missing pinned signed/notarized servers from the upstream tilrd GitHub Release, reuses verified completed servers unchanged, produces both signed/notarized DMGs and publishes nothing
- **WHEN** upload.command runs
- **THEN** it selects the last successful pair from build/latest-app-release.json, prints version/build/channel and publishes beta without changing or rebuilding files; absent history requires explicit version/build
- **AND** a failed subsequent build does not change the pointer; explicit release_all.py --publish remains an opt-in combined shortcut for beta only

#### Scenario: CI release
- **WHEN** the Release workflow runs
- **THEN** it acquires the pinned upstream server without compilation or signing and builds both DMGs, and its publish job publishes those same files as an RC to beta after a release/X.Y push or to stable from the stable tag created by merging the release PR, without rebuilding them in the publish job

#### Scenario: Saved stable upload selection
- **WHEN** upload.command selects a completed pair whose saved publication channel is stable
- **THEN** it refuses before CDN uploads or feed changes and explains that stable requires promotion of a verified CI RC
- **AND** neither CLI flags nor environment variables bypass this restriction

#### Scenario: Build-only publication guidance
- **WHEN** release.command completes a stable build without publication
- **THEN** it reports the completed artifacts and explains that stable requires promotion of a verified CI RC, without suggesting a direct upload command
- **AND** a completed beta build still prints the upload command for the unchanged tested pair
