## Why

Dragging a layout window between native hosts needs a relay that can wait for the drop to select its destination while preserving transactional ownership.

## What Changes

- Specify parked drag offers, drop acceptance with layout coordinates, and the commit reply.
- Specify offer expiration, source cancellation, and page ownership validation.

## Impact

The native handoff bridge supports drag tickets in addition to offers with an explicit target host. Existing command handoff continues to use the same transaction.
