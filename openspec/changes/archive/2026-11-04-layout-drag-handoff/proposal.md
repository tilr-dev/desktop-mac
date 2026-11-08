## Why

Dragging a layout window between native hosts needs a relay that can wait for the drop to select its destination while preserving transactional ownership.

## What Changes

- Specify parked drag offers, drop acceptance with layout coordinates, and the commit reply.
- Specify offer expiration, source cancellation, and page ownership validation.

## Impact

The native handoff bridge supports drag tickets in addition to offers with an explicit target host. Existing command handoff continues to use the same transaction.

## Native gesture

A plain header drag remains local until the pointer exits the native window. The shell then captures the panel and follows the cursor with a floating snapshot, selecting the handoff destination on release. Escape and release elsewhere preserve the source. The native session owns the gesture lifetime so a long hover does not expire an unclaimed transfer.
