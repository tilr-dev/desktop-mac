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
- **AND** scripts/build-gitpm.sh builds the static UniFFI XCFramework/generated bindings from local gitpm sources when they are newer, using cargo and rustup targets; without sources it keeps an installed pinned gitpm release; run.sh and release_all.py invoke it and generated artifacts remain gitignored
- **AND** building the commit in gitpm.pin from source yields the same plugin manager API as the pinned gitpm release
- **AND** new tunables are documented with purpose/units in Config.defaultText and parsed into Config, applying on reload unless explicitly marked at launch

#### Scenario: Stamp a development bundle
- **WHEN** run.sh builds the application
- **THEN** the built Info.plist version is `<latest reachable v-tag without v>-dev.<short commit>[.dirty]`, with base `0.0.0` when no tag exists
- **AND** the dirty suffix reflects tracked changes, the source Info.plist remains the `0.0.0-dev` placeholder, and real release versions are assigned by release tooling

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

### Requirement: Specification change authorization on main
Pull requests into main SHALL pass spec-change using the shared checker and read-only task credential to enforce intake Spec scope and Dan's authorization. PR authorization SHALL run only from the trusted pull_request_target workflow in main, never from candidate code. On merge_group checks_requested, the workflow SHALL report success as spec-change without repeating PR authorization; queue admission requires green PR checks.

#### Scenario: Existing specification is changed without authorization
- **WHEN** an intake-ready comment declares Spec scope and a pull request removes or changes existing specification lines without a matching spec-change entry from Dan
- **THEN** the check fails and lists the uncovered requirements

#### Scenario: Additions and the task's own change
- **WHEN** a pull request only adds requirements or edits its own change declared by intake
- **THEN** the check passes without an authorization block
- **AND** deltas that modify existing requirements still require authorization

#### Scenario: Authorized changes
- **WHEN** the task is in Review, Supervise, or Merge and every affected existing requirement and foreign change has a matching operation in Dan's spec-change block for this component
- **THEN** the check passes

#### Scenario: Bot impersonates authorization
- **WHEN** an authorization block is posted by a bot instead of Dan
- **THEN** the block does not authorize any changes

#### Scenario: Task predates scope declarations
- **WHEN** the task was created before 2026-10-22T21:02:26Z, is neither Done nor Canceled, and has a trusted intake-ready comment but no Spec scope line
- **THEN** the check passes as a legacy task
- **AND** the cutoff is the landing of the original authorization rule in dev

#### Scenario: Foreign change edited or archived
- **WHEN** a pull request edits or archives another task's change
- **THEN** the matching edit or archive entry from Dan is required

#### Scenario: Task data is unavailable
- **WHEN** the task cannot be identified, its creation date or column is unavailable, or its comments cannot be read completely
- **THEN** the check fails with an actionable error

#### Scenario: Local merge automation
- **WHEN** local merge automation invokes the checker with a repository, base, head, component, and task branch
- **THEN** the same authorization rules and exit status apply as in CI

#### Scenario: Candidate code cannot replace the checker
- **WHEN** a pull request changes checker scripts or workflow definitions
- **THEN** the check still runs the workflow from main, not a workflow file from the pull request
- **AND** the trusted workflow reads candidate Git objects without checking out or executing candidate files
- **AND** the shared checker content is verified against a digest pinned in main's workflow before execution, and a new digest takes effect only through a pull request into main
- **AND** the shared checker scripts are downloaded from an immutable commit named in main's workflow, so a change in their source takes effect only through a pull request into main
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
- **WHEN** a pull request adds a sentence, scenario, or scenario step inside a requirement already present in main
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
- **THEN** the operation requires authorization for the original requirement in main
- **AND** cyclic or ambiguous rename mappings fail the check

#### Scenario: A new requirement takes an existing scenario
- **WHEN** an inserted requirement heading moves existing scenario lines out of a requirement that remains in the specification
- **THEN** the check requires modify authorization for that existing requirement

#### Scenario: Reusing a renamed requirement's former name
- **WHEN** an own delta renames an existing requirement and another requirement takes its former name
- **THEN** each rename remains authorized against its own original requirement in main
- **AND** modifying or removing the first requirement under its new name requires permission for that original requirement

#### Scenario: A requirement's text moves under another existing requirement
- **WHEN** a pull request deletes or moves the heading of an existing requirement so that some of its text or scenarios fall under another requirement already present in main
- **THEN** authorization to remove or modify the requirement whose heading changed does not cover the change
- **AND** modify authorization for the requirement that absorbs the text is required

#### Scenario: Scope declaration names its own change ambiguously
- **WHEN** the latest intake-ready Spec scope line names no change or more than one change inside its own(...) part, or names a change outside it
- **THEN** the check fails with an error instead of treating any other word as the own change

#### Scenario: An existing archive shares the own change name
- **WHEN** a pull request edits an archive that already exists in main under the same change name as the task's own change
- **THEN** the archive is treated as a foreign change and edit authorization is required

#### Scenario: A new capability differs from an existing one only by letter case or Unicode form
- **WHEN** a pull request adds a capability directory whose name equals an existing or another added capability after case folding and Unicode normalization
- **THEN** the check fails with an error instead of treating it as a new capability
- **AND** the same applies when a delta in the task's own change names a capability that differs from an existing one only by letter case or Unicode form

#### Scenario: Branch names cannot select an unavailable or closed task
- **WHEN** the task branch names a nonexistent task or a task in Done or Canceled
- **THEN** the check exits with failure and an actionable error even if no Spec scope line exists

#### Scenario: Missing scope is not proof of legacy status
- **WHEN** a task without Spec scope was created at or after 2026-10-22T21:02:26Z, or has no trusted intake-ready comment
- **THEN** the check exits with failure instead of granting a legacy exception

#### Scenario: Grants expire outside the review lifecycle
- **WHEN** a task outside Review, Supervise, and Merge contains Dan's authorization block
- **THEN** the block grants no permission to modify existing requirements or foreign changes
- **AND** additions and edits of the declared own change that need no grant remain permitted
- **AND** a fresh invocation after the task enters Review, Supervise, or Merge evaluates its grants

#### Scenario: Offline task metadata
- **WHEN** local verification supplies a trusted export containing the issue metadata and complete comment activity
- **THEN** the same existence, creation date, closed-state, scope, and grant-lifetime rules apply
- **AND** a comments-only array or metadata naming a different task fails with an actionable error

#### Scenario: Merge queue requests the required check
- **WHEN** GitHub sends merge_group checks_requested for queued pull requests
- **THEN** the spec-change job reports success without reading pull_request fields, fetching candidate trees, downloading checkers, or accessing the task credential
- **AND** PR authorization still runs on pull_request_target and fails for unauthorized specification changes

### Requirement: Specification merge readiness diagnostics on main
Before fetching a pull request test merge for specification authorization, the trusted check SHALL read the pull request through the GitHub API with pull-requests read permission. It SHALL distinguish a conflict with main from a pending or stale merge result, and SHALL inspect candidate Git objects without executing candidate code.

#### Scenario: Pull request conflicts with main
- **WHEN** the API reports mergeable false for a head SHA matching the requested candidate SHA
- **THEN** the check fails immediately with a conflict diagnostic naming the task branch and instructing the author to merge main with `git merge main` and push
- **AND** it does not advise re-running the job

#### Scenario: GitHub is still computing the merge
- **WHEN** mergeable is null or the fetched merge commit does not have the requested candidate SHA as its second parent
- **THEN** the check waits and reads the API again for up to approximately 60 seconds
- **AND** it proceeds automatically once the API head SHA matches the requested candidate SHA, mergeable is true and the merge commit has the requested candidate SHA as its second parent
- **AND** it uses the first parent of that verified merge as the comparison baseline

#### Scenario: API response describes a stale head
- **WHEN** the API head SHA differs from the requested candidate SHA
- **THEN** the check treats that response as stale and reads the API again within the existing deadline
- **AND** it does not interpret its mergeable value as the candidate's conflict or readiness

#### Scenario: Command fails
- **WHEN** the API or Git command fails or times out
- **THEN** the check fails with a diagnostic identifying the command and preserving its error output

#### Scenario: Merge result remains stale
- **WHEN** the merge result remains pending or stale until the wait deadline
- **THEN** the check fails with the diagnostic that GitHub has not updated the merge result and advises re-running the job

#### Scenario: Deterministic regression coverage
- **WHEN** merge readiness decisions are tested
- **THEN** API responses, fetched parents, elapsed time and waits are controlled by fixtures without real waiting
- **AND** coverage includes a pending result becoming current, an immediate conflict, a stale API head becoming current, and stale results reaching the deadline

### Requirement: CI coverage for main and release branches
The CI workflow SHALL run the mac job for pull requests targeting main or release/** and pushes to main or release/**.

#### Scenario: Pull request targets a release branch
- **WHEN** a pull request targets release/0.1 or another branch matching release/**
- **THEN** CI runs the mac job

#### Scenario: Push updates a release branch
- **WHEN** a commit is pushed to a branch matching release/**
- **THEN** CI runs the mac job

#### Scenario: Main retains CI coverage
- **WHEN** a pull request targets main or a commit is pushed to main
- **THEN** CI runs the mac job
