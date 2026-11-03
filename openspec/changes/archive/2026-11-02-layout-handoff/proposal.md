## Why

A layout window needs to move between native hosts while keeping its identity and saved content. Recreating it from a frozen snapshot lets live services reconnect without moving DOM nodes.

## What Changes

- Add a revisioned, one-use handoff protocol with provisional target creation and commit or rollback.
- Add layout.handoff, a page command with a host picker, CLI window move and MCP move.
- Relay transfers between trusted pages of the same application in the native shell.

## Impact

The source keeps its window until the target acknowledges restoration. Invalid targets, target closure and expiration restore source usability.
