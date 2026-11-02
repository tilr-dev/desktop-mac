# Expose embedded gitpm commands through Control

## Why
Automation needs the same pinned gitpm library and workspace as the running app, including mutations serialized with plugin management.

## What Changes
- Add a `gitpm` Control request accepting a command name and JSON arguments and returning JSON results or structured gitpm errors.
- Route every gitpm FFI command through the existing plugin-manager service and its serial queue.
- Pin the embedded library to the release candidate containing the complete command API.
- Preserve the existing read-only `plugin-manager` status request and the absence of a page bridge.

## Impact
- App Control protocol, plugin-manager service, pinned gitpm dependency and integration probes.
