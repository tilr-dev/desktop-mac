## MODIFIED Requirements

### Requirement: Instance control protocol
Tilr SHALL expose newline-delimited JSON requests on its instance's Unix control socket, with request identifiers echoed in responses and errors returned to the caller.

#### Scenario: Inspect or operate an app
- **WHEN** a client sends a control request
- **THEN** omitted host and app selection targets the key window’s app; app listing reports name, site, URL, current and loaded state and the host IDs where each app is open
- **AND** switch focuses an existing window of the requested app or opens a new one; legacy `slide` is accepted without animation; snapshot writes a PNG at the requested path and returns its dimensions
- **AND** eval executes asynchronous JavaScript and call invokes the requested page service method/property, returning results or errors
- **AND** commands needing an app with no open window create its page and wait up to control.load_timeout (default 10 seconds); an empty configured socket disables Control
- **AND** a live existing socket is not replaced; a stale socket is removed on startup

#### Scenario: Address a native host
- **WHEN** a request includes `host`
- **THEN** that host selects the page, with an unknown host or a conflicting app returning a clear error before any operation
- **AND** every socket command accepts host selection; instance-wide commands validate it without changing their scope
- **WHEN** app is supplied without host and multiple windows show that app
- **THEN** the most recently key window of that app is selected; an app with no window is opened as before

## ADDED Requirements

### Requirement: Native shell window commands
Control SHALL provide `shell` operations list, open, close, focus and move for native windows independently of page layout windows.

#### Scenario: Manage a duplicate window
- **WHEN** shell open names an app and optionally a frame
- **THEN** a new host is created even if the app already has an open window, and its host ID is returned
- **AND** list reports each host ID, app, frame, screen, key state and Space membership
- **AND** frames use AppKit screen coordinates in points as x, y, width and height; sizes must be positive and all numbers finite
- **WHEN** close, focus or move names a host
- **THEN** the existing window is closed, focused without activating the application, or placed at the required frame; other hosts are unaffected
- **AND** missing or invalid arguments return errors without creating or modifying a window
- **AND** moving a native fullscreen window reports that it must leave fullscreen first; moving a screen-filling desktop window switches it to window mode
