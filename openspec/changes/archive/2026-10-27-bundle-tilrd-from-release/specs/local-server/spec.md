## MODIFIED Requirements

### Requirement: Offline bootstrap and independent updates
Tilr SHALL bundle an unchanged signed/notarized server from the upstream tilrd GitHub Release pinned by server-release.json and maintain independent application and server version/build/channel tracks.

#### Scenario: Start offline or with a newer installation
- **WHEN** a public app starts
- **THEN** its bundled signed server, verified against the upstream release version including its upstream commit, can install offline without Node, npm, Git or a JavaScript CLI
- **AND** a newer compatible installed server wins; incompatible protocols/app-build ranges or reused build numbers with changed contents fail without stopping or downgrading it
- **AND** signed Info.plist metadata supplies the supported protocol, bundled identity, server feed base URL and verification key
- **AND** app Sparkle updates and `/server/macos/<arch>/<stable|beta>.json` server updates remain separate
