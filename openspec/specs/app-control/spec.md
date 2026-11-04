# app-control Specification

## Purpose
Define instance-scoped automation, bounded console capture, plugin-manager inspection and SSH agent stream lifetime.

## Requirements

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

### Requirement: Bounded console capture
Tilr SHALL capture console output only when `control.console_capture` is enabled at launch, buffering up to `control.console` entries (default 500).

#### Scenario: Large console object
- **WHEN** a page logs values
- **THEN** messages are batched per microtask and each text is cut to `control.console_entry_max` characters (default 4096)
- **AND** object traversal stops at the cut while producing the same prefix as complete JSON serialization; it does not serialize the entire large object first
- **AND** console reads return time/type/text entries oldest first and optionally clear them after retrieval

### Requirement: Plugin manager control and Git errors
Tilr SHALL statically link the gitpm UniFFI library, support asynchronous service calls with structured `kind`/`message` errors, and expose every gitpm FFI command through Control on the configured plugin workspace, without a plugin-manager UI or page bridge. The existing `plugin-manager` status request SHALL remain read-only.

#### Scenario: Manage web plugins
- **WHEN** plugin-manager configuration reloads
- **THEN** the manager uses the configured workspace (default `<config>/plugins`) and catalog (default `https://pkg.tilr.dev`)
- **AND** a status read does not open or create a workspace or acquire a mutation lock
- **AND** operations requiring Git, including install/update/rollback/restore/fork/auth and author repository inspection/editing, run preflight and return a `git` error with Command Line Tools guidance if Git is unavailable, without a system stub installation popup

#### Scenario: Migrate legacy plugin distribution at launch
- **WHEN** the application starts with installed plugins in its configured workspace
- **THEN** it invokes gitpm syncDist once so dist contains only active plugins, including migration from workspaces written by gitpm 0.4 or earlier
- **AND** the outcome is logged, synchronization failure does not abort launch, repeating the migration is safe, and unmanaged files remain untouched
- **AND** missing or empty workspaces are read without creating them, and probes exercise temporary workspaces instead of migrating the configured one

#### Scenario: Invoke embedded gitpm through Control
- **WHEN** a client sends `cmd: "gitpm"` with a command name and JSON arguments
- **THEN** the app executes that command through its embedded pinned gitpm library; workspace operations use the plugin-manager workspace and returns its JSON result with the request identifier
- **AND** all commands use the same service queue as existing plugin-manager operations, so mutations cannot race with them
- **AND** every FFI command is available, including workspace initialization, commit, remote configuration and catalog operations
- **AND** callers cannot redirect a workspace operation to another workspace; author operations accept the FFI directory argument for their source repository

#### Scenario: Report gitpm command errors
- **WHEN** a gitpm command fails
- **THEN** Control returns a structured JSON error containing its gitpm code, kind and message
- **AND** unknown commands and invalid arguments return clear errors before mutation

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

### Requirement: Package replacement integration
The app's gitpm service SHALL use the pinned package-manager API for replacement without confirmation, preserving structured incompatibility errors, and SHALL restore the original provider by replacing it with itself.

#### Scenario: Reject an invalid replacement
- **WHEN** the plugin-manager probe attempts replacement with a package that does not declare the original in its replacements
- **THEN** the service returns the library's structured invalid-argument error

#### Scenario: Refuse an incompatible provider
- **WHEN** an installed consumer does not accept the version provided by a proposed replacement
- **THEN** replacement fails with `incompatible_replacement` and identifies the consumer
- **AND** the consumer keeps its previous provider

#### Scenario: Restore the original provider
- **WHEN** a replacement is active and the service replaces the original with itself
- **THEN** consumers resolve to the installed original again
- **AND** the operation requires no confirmation parameter

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

### Requirement: Native layout handoff relay
The shell SHALL relay revisioned one-use handoff offers between trusted loaded pages of the same application, bind acknowledgements to the target page, commit successful transfers and cancel on error, expiration or page departure. The bridge SHALL expose only Control socket `shell list` for choosing a target.

#### Scenario: Real-page transfer
- **WHEN** a trusted page sends `handoff.offer {ticket, payload, targetHost}` and the target restores `handoff.accept {ticket, payload}` and acknowledges it
- **THEN** the source receives `handoff.commit {ticket}` and the target retains the restored window

#### Scenario: Probe waits for runtime initialization
- **WHEN** either page finishes navigation before its asynchronous runtime boot completes
- **THEN** the handoff probe waits for runtime publication and the layout service on both pages before moving a window
- **AND** a navigation failure or readiness deadline fails the probe explicitly instead of continuing with an unready page
- **AND** the standalone handoff probe uses a composed runtime site; the general native GUI probe remains usable with the legacy site

#### Scenario: Page disappears
- **WHEN** the target closes or navigates before acknowledgement
- **THEN** the relay sends `handoff.cancel` to surviving pages, rejects the initiating call and rejects late acknowledgements

#### Scenario: Untrusted origin or other application
- **WHEN** an embedded page, foreign origin or another application's host attempts a transfer
- **THEN** the relay rejects it without dispatching the payload

#### Scenario: Commit completion lease
- **WHEN** both commit event callbacks finish but the source has not confirmed its shared-store decision with `handoff.finalized`
- **THEN** the relay retains the pending lease and cancels provisional windows on page departure or expiration
- **AND** it never replies to an already resolved offer a second time

### Requirement: Native layout drag handoff relay
The shell SHALL park untargeted `handoff.offer` tickets until a valid `handoff.accept` selects another current page of the same app and finite layout coordinates. It MUST bind tickets to their source and use acknowledged handoff after selection. Compatibility offers SHALL expire after ten seconds; native pointer offers SHALL remain valid for the held gesture, with the transaction deadline starting on target selection.

#### Scenario: Park an offer until a drop
- **WHEN** a loaded current source page offers a fresh ticket with its host identity, window identity and a valid positive integer revision, without a target host
- **THEN** the relay parks the offer and leaves its reply pending without sending a restore event to another page
- **AND** a duplicate offer for the parked ticket is rejected with `Handoff ticket already used`

#### Scenario: Claim a ticket at the drop position
- **WHEN** a different loaded current page of the same application sends `handoff.accept {ticket, position}` for a parked offer with finite numeric non-boolean `x` and `y`
- **THEN** the relay selects that page's native host, inserts the position into the payload and starts the existing acknowledged handoff transaction
- **AND** the accepting call receives `{accepted: true}`
- **AND** after successful commit callbacks the source offer reply contains `ticket`, `targetHost` and `position`
- **AND** source finalization completes the transaction

#### Scenario: Reject an invalid drop
- **WHEN** acceptance references an unavailable ticket, the source page, a different application, an unloaded or non-current page, or missing or invalid coordinates
- **THEN** the accepting call fails with `Invalid drop or unavailable handoff ticket`
- **AND** it does not claim a parked offer or transfer ownership

#### Scenario: End an unclaimed drag
- **WHEN** the source sends `handoff.dragend {ticket}` while its offer is still parked
- **THEN** the relay cancels the offer with `Drag cancelled`, notifies the source and rejects the pending offer reply
- **AND** the source retains its window and the ticket cannot be reused

#### Scenario: End a claimed drag
- **WHEN** a drop has already claimed an offer before the source sends `handoff.dragend {ticket}`
- **THEN** drag end returns `{accepted: true}` without cancelling the running handoff transaction

#### Scenario: Cancel a parked offer explicitly
- **WHEN** the source sends `handoff.cancel {ticket}` for its parked offer
- **THEN** the relay cancels it with `Handoff cancelled` and returns `{accepted: true}` to the cancellation call
- **AND** the source retains its window and the ticket cannot be reused

#### Scenario: Reject cancellation by another page
- **WHEN** another page sends `handoff.dragend` or `handoff.cancel` for a parked offer
- **THEN** the call fails with `Handoff belongs to another page` and leaves the offer parked

#### Scenario: Expire an unclaimed offer
- **WHEN** an offer remains unclaimed for ten seconds after registration
- **THEN** the relay cancels it with `Handoff timed out`, notifies the source and rejects the pending offer reply
- **AND** the source retains its window and a later drop cannot claim the consumed ticket

#### Scenario: Source page departs before a drop
- **WHEN** the source closes or navigates while its offer is parked
- **THEN** the relay cancels it with `Handoff page closed or navigated` and rejects the pending offer reply
- **AND** a later drop cannot claim the consumed ticket

### Requirement: Native pointer drag takeover
The shell SHALL preserve local header drag until the pointer exits the source native frame, then prepare and snapshot its panel and track the image above other windows. Release over another eligible page SHALL initiate acknowledged handoff. Escape, release elsewhere, snapshot failure or source departure MUST retain the source and remove tracking resources. Asynchronous callbacks SHALL belong to the current gesture.

#### Scenario: Exit and snapshot
- **WHEN** a held pointer first leaves the source native frame
- **THEN** native tracking asks the source page to end local movement, snapshots the prepared panel and follows the screen pointer with the original grab offset
- **AND** movement within the source frame before exit creates no handoff offer or floating snapshot

#### Scenario: Drop during asynchronous preparation
- **WHEN** the pointer is released over an eligible destination before preparation or snapshot completion
- **THEN** the release position is retained and handoff runs once preparation succeeds
- **AND** a failed snapshot cancels the gesture and restores the source

#### Scenario: Cancel and page departure
- **WHEN** Escape is pressed, the pointer is released outside eligible Tilr content, or the source page leaves
- **THEN** tracking monitors and the floating snapshot are removed and the source is retained
- **AND** late snapshot or preparation replies cannot resurrect that gesture or affect a subsequent one

#### Scenario: Long native gesture
- **WHEN** a native gesture remains held beyond the compatibility offer lifetime
- **THEN** it remains eligible for drop without extending any running handoff transaction deadline
