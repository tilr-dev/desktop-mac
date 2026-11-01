
## MODIFIED Requirements

### Requirement: Session and host isolation
Tilr SHALL create a separate native session per window page, keep the main interface WKWebView in the app and embedded browser views in the browser plugin, and retain instance-scoped profile storage identifiers.

#### Scenario: Configure a session
- **WHEN** a session starts or configuration reloads
- **THEN** enabled defaults are browser-webkit and audio, request timeout defaults to 30 seconds at launch, and plugin options hot reload through configurationDidChange
- **AND** browser configuration is provided separately, with host inspectable/high_refresh_rate values overriding user keys and fixed to the page's launch values
- **AND** the SDK supplies generic AppKit overlay/surface containers, JSON configuration, event delivery and site URL resolution without depending on app internals; existing browser cookies and profile locations remain stable, macOS supplies system WebKit and iPad retains its built-in implementation
- **AND** the audio provider supplies AVPlayer, Now Playing and media-key integration
- **AND** closing a window stops only that page’s native resources; navigation and session stop are distinct, and audio survives page navigation
