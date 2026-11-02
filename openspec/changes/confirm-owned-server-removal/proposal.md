# Confirm local server removal

## Why
Removing an application-installed server currently deletes its executable pair and startup registration immediately, despite the action being labeled with an ellipsis.

## What Changes
- Ask “Remove the local server?” before removing an application-installed pair.
- Explain that the running server remains until it exits and state, token and logs are preserved.
- Cancel leaves the installation and running daemon unchanged.

## Impact
- Affected spec: local-server, Removal preserves user state.
- Affected code: LocalServerHost and its lifecycle regression fixture.
