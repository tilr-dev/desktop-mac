# development Specification

## Purpose
Define isolated development probes, native-module verification and the evidence required for release acceptance.

## Requirements

### Requirement: Isolated development and regression probes
Tilr development SHALL use Swift Package/AppKit without an Xcode project and exercise app behavior in a separate instance.

#### Scenario: Run a check
- **WHEN** run.sh --test or --test --probe runs
- **THEN** it uses dev.tilr.mac.test config, its own socket/PID/storage/window and a .test bundle identifier to avoid inheriting the user's Dock Space assignment
- **AND** probe checks page plumbing, native events, bounded console serialization, PNG snapshot, palette, app switching/sliding, lazy tabs, window frame/hit boundaries and desktop movement, then exits
- **AND** tests address the isolated socket through --socket or TILR_CONTROL and never restart/kill the user's Tilr without explicit authorization
- **AND** native package development requires macOS, Python 3, Xcode/Command Line Tools with Swift 6; TypeScript/plugin development requires Node >=22.18, while plain HTML/CSS/JS requires no npm
- **AND** scripts/build-gitpm.sh builds the static UniFFI XCFramework/generated bindings when library sources are newer, using cargo and rustup targets; run/release invoke it and generated artifacts remain gitignored
- **AND** new tunables are documented with purpose/units in Config.defaultText and parsed into Config, applying on reload unless explicitly marked at launch

### Requirement: Native plugin verification coverage
The native plugin workflow SHALL exercise real signed modules through SDK/package tests and the actual application loader, with GUI checks separated from headless checks.

#### Scenario: Validate native extraction
- **WHEN** SDK/native Swift tests and scripts/test_native_plugins.py run
- **THEN** they cover bootstrap loading, external installation, version selection, rollback, unchanged app binary/signature, tampering, ABI mismatch and missing entry point
- **AND** --gui requires a logged-in desktop and includes browser/app probes; the JavaScript native bridge is tested in the web repository

### Requirement: Exact release verification and evidence
Release acceptance SHALL verify the actual completed DMGs and distinguish artifact verification, compilation and manual runtime evidence.

#### Scenario: Verify an artifact
- **WHEN** verify_release.py checks a release directory
- **THEN** it checks archive SHA, image integrity/signature/stapling, mounts read-only, checks app signature/stapling/Gatekeeper/version/architecture/feed/key and always detaches
- **AND** verification.json records artifact checks rather than a GUI pass; --launch copies the verified app to build/local-tests and uses isolated config/PID/socket/storage and --no-updates without replacing the user's app
- **AND** Intel compilation or verification on ARM does not establish Intel execution; acceptance requires actual-architecture runtime, clean browser-downloaded Finder installation, external site paths with spaces/Unicode and real beta Sparkle N-to-N+1 installation/relaunch
- **AND** independent app/server upgrade checks preserve user config, external folders, live shell PIDs and newer compatible servers, including offline bootstrap; signature/downgrade checks remain part of acceptance
- **AND** reports state verified URLs, version/build/channel and actual test status, naming a failed command/access boundary rather than claiming notarization, public delivery or GUI success from unit tests

### Requirement: Private API inventory maintenance
Development SHALL maintain the documented private API inventory and check guards/fallbacks when macOS changes.

#### Scenario: Review supported systems
- **WHEN** a macOS release is evaluated
- **THEN** Shell desktop CGS/SLS operations, browser hover selector, Debug WebContent PID, app/provider WebKit high-refresh features and Memory inspector selectors are checked against their documented guarded calls and fallbacks
- **AND** an unavailable API is not treated as evidence of successful desktop movement, native hover, refresh rate or inspector display

### Requirement: Specification change authorization on dev
Pull requests into dev SHALL pass the required spec-change check. One shared checker SHALL enforce intake Spec scope and accept authorization only from Dan's comments, using the dedicated read-only task credential. Other tests SHALL remain local for dev.

#### Scenario: Existing specification is changed without authorization
- **WHEN** an intake-ready comment declares Spec scope and a pull request removes or changes existing specification lines without a matching spec-change entry from Dan
- **THEN** the check fails and lists the uncovered requirements

#### Scenario: Additions and the task's own change
- **WHEN** a pull request only adds requirements or edits its own change declared by intake
- **THEN** the check passes without an authorization block
- **AND** deltas that modify existing requirements still require authorization

#### Scenario: Authorized changes
- **WHEN** every affected existing requirement and foreign change has a matching operation in Dan's spec-change block for this component
- **THEN** the check passes

#### Scenario: Bot impersonates authorization
- **WHEN** an authorization block is posted by a bot instead of Dan
- **THEN** the block does not authorize any changes

#### Scenario: Task predates scope declarations
- **WHEN** the task's intake-ready comments contain no Spec scope line
- **THEN** the check passes as a legacy task

#### Scenario: Foreign change edited or archived
- **WHEN** a pull request edits or archives another task's change
- **THEN** the matching edit or archive entry from Dan is required

#### Scenario: Task data is unavailable
- **WHEN** the task cannot be identified or its comments cannot be read completely
- **THEN** the check fails with an actionable error

#### Scenario: Local merge automation
- **WHEN** local merge automation invokes the checker with a repository, base, head, component, and task branch
- **THEN** the same authorization rules and exit status apply as in CI

#### Scenario: Candidate code cannot replace the checker
- **WHEN** a pull request changes checker scripts or workflow definitions
- **THEN** the trusted workflow reads candidate Git objects without checking out or executing candidate files
- **AND** the shared checker content is verified against a digest fixed in the trusted workflow before execution
- **AND** only the checker process receives the read-only task credential

#### Scenario: Malformed scope declaration
- **WHEN** the latest intake-ready Spec scope line is empty or does not identify an own change
- **THEN** the check fails with an error instead of accepting the task as legacy

#### Scenario: A renamed requirement is also modified in a delta
- **WHEN** an own change renames an existing requirement and modifies it under the new name
- **THEN** authorization to rename the original requirement does not authorize modifying it
- **AND** modification authorization is checked against the original requirement name

#### Scenario: A foreign change is rewritten while archived
- **WHEN** a foreign change is archived with altered file contents
- **THEN** both archive and edit authorization are required for that change

#### Scenario: Text is inserted into an existing requirement
- **WHEN** a pull request adds a sentence, scenario, or scenario step inside a requirement already present in dev
- **THEN** matching modify authorization for that existing requirement is required
- **AND** adding a separate new requirement remains allowed without authorization

#### Scenario: An active foreign change is edited while copied to archive
- **WHEN** a foreign change is copied unchanged to archive while its active source is modified
- **THEN** both archive and edit authorization are required for that change

#### Scenario: A previous foreign archive is changed while another is created
- **WHEN** a pull request edits or removes an existing foreign archive and creates a new archive copy of the same change
- **THEN** archive authorization for the new copy does not authorize editing the previous archive

#### Scenario: Chained requirement renames retain their original authorization
- **WHEN** an own delta renames an existing requirement through intermediate names and modifies or removes it
- **THEN** the operation requires authorization for the original requirement in dev
- **AND** cyclic or ambiguous rename mappings fail the check

#### Scenario: A new requirement takes an existing scenario
- **WHEN** an inserted requirement heading moves existing scenario lines out of a requirement that remains in the specification
- **THEN** the check requires modify authorization for that existing requirement
