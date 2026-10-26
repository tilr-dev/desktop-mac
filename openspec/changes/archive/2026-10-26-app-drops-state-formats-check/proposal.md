## Why

The app duplicates the daemon’s reload-state compatibility checks and rejects updates before the daemon can decide whether it can preserve live sessions.

## What Changes

- Remove app-side state-formats queries before replacement and reload.
- Delegate reload-state compatibility to tilrd and retain authenticated expected-version checks.
- Report a refused reload while leaving the old supervisor and its terminals running.

## Capabilities

### Modified Capabilities
- local-server: authenticated and compatible replacement.

## Impact

Managed server installation, reload readiness tests, and the local-server specification.
