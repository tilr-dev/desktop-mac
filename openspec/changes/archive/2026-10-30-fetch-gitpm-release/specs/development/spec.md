## MODIFIED Requirements

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
