## Context
The saved changes predate the current gitpm replacement API. Preserve that API and the current dependency pin while bringing over development version stamping and explicit distribution synchronization.

## Decisions
- Compute the development version before building, preserving the committed plist template. Ignore untracked files when deciding whether tracked sources are dirty.
- Treat only numeric template versions as release candidates; remembered releases and explicit overrides keep their existing precedence.
- Run syncDist once per app launch against the initially configured workspace. Use a separate asynchronous service with captured launch settings so configuration reload cannot redirect the migration, close it after the call, and log failures without preventing startup; status reads remain read-only. Skip missing/empty workspaces without creating them and isolate probes from the configured workspace.

## Validation
Exercise release selection with a placeholder, history and explicit override; version stamping in temporary repositories with and without tags and tracked changes; real gitpm migration of stale distribution contents and repeated synchronization through the application probe.
