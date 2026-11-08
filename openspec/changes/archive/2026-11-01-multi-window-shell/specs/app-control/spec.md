
## MODIFIED Requirements

### Requirement: Instance control protocol
Tilr SHALL expose newline-delimited JSON requests on its instance's Unix control socket, with request identifiers echoed in responses and errors returned to the caller.

#### Scenario: Inspect or operate an app
- **WHEN** a client sends a control request
- **THEN** omitted app selection targets the key window’s app; app listing reports name, site, URL, current and loaded state
- **AND** switch focuses an existing window of the requested app or opens a new one; legacy `slide` is accepted without animation; snapshot writes a PNG at the requested path and returns its dimensions
- **AND** eval executes asynchronous JavaScript and call invokes the requested page service method/property, returning results or errors
- **AND** commands needing an app with no open window create its page and wait up to control.load_timeout (default 10 seconds); an empty configured socket disables Control
- **AND** a live existing socket is not replaced; a stale socket is removed on startup
