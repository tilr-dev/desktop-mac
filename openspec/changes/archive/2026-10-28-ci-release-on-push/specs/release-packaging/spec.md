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
- **THEN** it acquires the pinned upstream server without compilation or signing and builds both DMGs, and its publish job publishes those same files as an RC to beta automatically after a push to release/X.Y without rebuilding them

#### Scenario: Saved stable upload selection
- **WHEN** upload.command selects a completed pair whose saved publication channel is stable
- **THEN** it refuses before CDN uploads or feed changes and explains that stable requires promotion of a verified CI RC
- **AND** neither CLI flags nor environment variables bypass this restriction

#### Scenario: Build-only publication guidance
- **WHEN** release.command completes a stable build without publication
- **THEN** it reports the completed artifacts and explains that stable requires promotion of a verified CI RC, without suggesting a direct upload command
- **AND** a completed beta build still prints the upload command for the unchanged tested pair

### Requirement: Persistent release numbering
The release coordinator SHALL reserve monotonically increasing local builds under a lock without resetting on marketing-version changes.

#### Scenario: Inspect or reserve
- **WHEN** release.command --status runs
- **THEN** it reads source version, remembered release version, highest local/reserved build, next build, latest completed pair and pinned server without Keychain access, build reservation or CDN lookup
- **WHEN** a build passes access preflight
- **THEN** --version/--build/--channel select metadata, otherwise current version and next build apply; explicit builds exceed local failed/preview reservations, source Info.plist is unchanged and the chosen version is remembered on reservation
- **AND** rerunning after failure chooses a new number; explicit --resume reuses only matching completed verified artifacts, and incomplete output must be preserved/moved aside before retry
- **AND** build history must be retained and CDN numbers checked when changing machines; local numbering does not assert installed or public versions

#### Scenario: No release version in the template
- **WHEN** the source Info.plist contains `0.0.0-dev`
- **THEN** it is ignored as a release version; numeric release history or an explicit --version supplies the version
- **AND** without either, selection fails with `No release version yet; pass --version` without reserving a build
- **AND** --status and the automatic build preamble display the missing version without reserving or failing, so an explicit --version can initialize the first release

#### Scenario: CI release numbers
- **WHEN** the Release workflow runs on a runner without local history
- **THEN** it takes the numeric version from the shared release-please workflow, resolves build as the highest build in both architecture appcasts across stable and beta plus one, and passes these explicitly to packaging and publication; local reservations are unchanged
