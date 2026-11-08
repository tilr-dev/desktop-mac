## MODIFIED Requirements

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
