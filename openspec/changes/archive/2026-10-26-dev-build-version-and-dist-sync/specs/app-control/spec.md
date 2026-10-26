## MODIFIED Requirements

### Requirement: Plugin manager control and Git errors
Tilr SHALL statically link the gitpm UniFFI library, support asynchronous service calls with structured `kind`/`message` errors, and provide read-only plugin-manager status through Control without a plugin-manager UI or page bridge.

#### Scenario: Manage web plugins
- **WHEN** plugin-manager configuration reloads
- **THEN** the manager uses the configured workspace (default `<config>/plugins`) and catalog (default `https://pkg.tilr.dev`)
- **AND** a status read does not open or create a workspace or acquire a mutation lock
- **AND** install/update/rollback/restore/fork/auth operations requiring Git run preflight and return a `git` error with Command Line Tools guidance if Git is unavailable, without a system stub installation popup

#### Scenario: Migrate legacy plugin distribution at launch
- **WHEN** the application starts with installed plugins in its configured workspace
- **THEN** it invokes gitpm syncDist once so dist contains only active plugins, including migration from workspaces written by gitpm 0.4 or earlier
- **AND** the outcome is logged, synchronization failure does not abort launch, repeating the migration is safe, and unmanaged files remain untouched
- **AND** missing or empty workspaces are read without creating them, and probes exercise temporary workspaces instead of migrating the configured one
