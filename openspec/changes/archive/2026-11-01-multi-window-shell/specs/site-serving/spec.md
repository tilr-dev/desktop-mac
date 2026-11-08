
## MODIFIED Requirements

### Requirement: Site reload and page lifecycle
Tilr SHALL watch loaded app folders and refresh changed content without mixing page navigation state or leaking page-owned resources.

#### Scenario: Source changes
- **WHEN** a loaded app folder changes
- **THEN** changes are gathered using `watch.latency` (default 0.2 seconds); changes confined to `plugins/` use the page's plugin hot-reload entry point when available, otherwise the page reloads
- **AND** changing the configured site updates the handler root and navigates every open window of the affected app immediately; future windows use the updated site
- **AND** changing the app itself replaces its web view to reset navigation history while retaining its configured data store and bridges
- **AND** navigation/reload closes SSH agent streams and releases or temporarily parks page-owned browser views for adoption; native audio sessions survive page navigation
