## Why

The server no longer watches its executable for replacement. The app currently replaces the binary and waits for the new version without asking the running supervisor to reload, so a live update never becomes ready.

## What Changes

- Explicitly request session-preserving reload after atomic replacement of a running server.
- Keep the installed update and recovery files when the reload request fails, and show an explicit error.
- Preserve authenticated expected-version readiness checks and existing bootstrap/start behavior.

## Capabilities

### Modified Capabilities
- local-server: authenticated and compatible replacement.

## Impact

Managed local server installation and its regression tests.
