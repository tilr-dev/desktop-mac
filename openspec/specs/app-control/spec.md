# app-control Specification

## Purpose
Define instance-scoped automation, bounded console capture, plugin-manager inspection and SSH agent stream lifetime.

## Requirements

### Requirement: Instance control protocol
Tilr SHALL expose newline-delimited JSON requests on its instance's Unix control socket, with request identifiers echoed in responses and errors returned to the caller.

#### Scenario: Inspect or operate an app
- **WHEN** a client sends a control request
- **THEN** omitted app selection targets the current app; app listing reports name, site, URL, current and loaded state
- **AND** switch selects the requested app and honors `slide: true`; snapshot writes a PNG at the requested path and returns its dimensions
- **AND** eval executes asynchronous JavaScript and call invokes the requested page service method/property, returning results or errors
- **AND** commands needing an unloaded page load it and wait up to control.load_timeout (default 10 seconds); an empty configured socket disables Control
- **AND** a live existing socket is not replaced; a stale socket is removed on startup

### Requirement: Bounded console capture
Tilr SHALL capture console output only when `control.console_capture` is enabled at launch, buffering up to `control.console` entries (default 500).

#### Scenario: Large console object
- **WHEN** a page logs values
- **THEN** messages are batched per microtask and each text is cut to `control.console_entry_max` characters (default 4096)
- **AND** object traversal stops at the cut while producing the same prefix as complete JSON serialization; it does not serialize the entire large object first
- **AND** console reads return time/type/text entries oldest first and optionally clear them after retrieval

### Requirement: Plugin manager control and Git errors
Tilr SHALL statically link the gitpm UniFFI library, support asynchronous service calls with structured `kind`/`message` errors, and provide read-only plugin-manager status through Control without a plugin-manager UI or page bridge.

#### Scenario: Manage web plugins
- **WHEN** plugin-manager configuration reloads
- **THEN** the manager uses the configured workspace (default `<config>/plugins`) and catalog (default `https://pkg.tilr.dev`)
- **AND** a status read does not open or create a workspace or acquire a mutation lock
- **AND** install/update/rollback/restore/fork/auth operations requiring Git run preflight and return a `git` error with Command Line Tools guidance if Git is unavailable, without a system stub installation popup

### Requirement: SSH agent forwarding bridge
Tilr SHALL provide page-owned SSH agent streams through `tilrAgent`, forwarding agent requests rather than storing private keys.

#### Scenario: Open and close streams
- **WHEN** the app page requests agent forwarding
- **THEN** socket selection uses configured `ssh_agent.socket`, otherwise SSH_AUTH_SOCK, the global SSH config IdentityAgent, the 1Password agent path, then launchctl's SSH_AUTH_SOCK
- **AND** probe/open/data/close operations exchange base64 data and `tilr-agent` ready/open/data/close events, subject to configured stream/chunk limits (defaults 64 streams and 65536 bytes)
- **AND** closing a stream prevents later delivery; navigation closes all page-owned streams without forwarding events into the next page

### Requirement: Native control routing
Tilr SHALL expose plugin inventory and native control services through Control separately from the web message bridge.

#### Scenario: Native request
- **WHEN** a client uses native-plugins or native-call
- **THEN** inventory reports available/loaded plugins and errors, and native-call routes the requested service and JSON request to the plugin
- **AND** existing browser automation commands route through the native browser provider
