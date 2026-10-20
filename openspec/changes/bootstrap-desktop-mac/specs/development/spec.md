## ADDED Requirements

### Requirement: Isolated development and regression probes
Tilr development SHALL use Swift Package/AppKit without an Xcode project and exercise app behavior in a separate instance.

#### Scenario: Run a check
- **WHEN** run.sh --test or --test --probe runs
- **THEN** it uses dev.tilr.mac.test config, its own socket/PID/storage/window and a .test bundle identifier to avoid inheriting the user's Dock Space assignment
- **AND** probe checks page plumbing, native events, bounded console serialization, PNG snapshot, palette, app switching/sliding, lazy tabs, window frame/hit boundaries and desktop movement, then exits
- **AND** tests address the isolated socket through --socket or TILR_CONTROL and never restart/kill the user's Tilr without explicit authorization
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
