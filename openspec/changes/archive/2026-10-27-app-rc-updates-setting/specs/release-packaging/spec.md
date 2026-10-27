## MODIFIED Requirements

### Requirement: Architecture-specific signed artifacts
Public app releases SHALL contain two DMGs, arm64 and x86_64, sharing marketing version/build, with no universal packaging option.

#### Scenario: Build public artifacts
- **WHEN** release.py/release_all.py builds an architecture
- **THEN** each Mach-O, including all five Sparkle executables, is audited/thinned to that architecture, embedded code is signed inside-out with hardened runtime and secure timestamp, signatures are verified and app/DMG notarized and stapled
- **AND** public DMGs are named Tilr-<version>-<build>-<arch>.dmg and published at https://cdn.tilr.dev/mac/<arch>/Tilr-<version>-<build>-<arch>.dmg
- **AND** the DMG contains Tilr.app and an Applications link; user configuration and installed applications are untouched; there is no unsigned production fallback or App Sandbox requirement
- **AND** the verification public key and runtime-feed-selection marker are embedded in the signed bundle without a channel or SUFeedURL; for the same architecture/version/build/key, stable and beta packaging produce identical Info.plist bytes
- **AND** release.json is written only after completion and records identity/metadata and archive SHA-256; existing completed output is never overwritten
- **AND** AppIcon includes standard/retina sizes and Info.plist identifies it through CFBundleIconFile
