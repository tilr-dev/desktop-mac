## ADDED Requirements

### Requirement: Runtime host identity
Tilr SHALL expose immutable `window.__tilrHost` metadata containing `host` as the native window's stable UUID string and `primary` as a boolean to its main runtime page before page scripts execute. The runtime SHALL use the stable `main` host identity when native metadata is absent in a standalone browser.

#### Scenario: Independent pages share application storage
- **WHEN** two windows of the same application load their runtime pages
- **THEN** each main page sees its own host UUID at document start
- **AND** only the first valid window of that application in persisted creation order has `primary` true when its page is created
- **AND** application origins and shared website storage remain unchanged
- **AND** focus changes do not alter the metadata

#### Scenario: Reload and restore a host
- **WHEN** a page reloads or its native window is restored from the saved workspace
- **THEN** the page receives the same host UUID before its scripts execute
- **AND** the metadata object and its global property cannot be changed by ordinary page assignments

#### Scenario: Open the runtime in a browser
- **WHEN** the runtime loads without native host metadata
- **THEN** its layout uses the stable `main` host identity
