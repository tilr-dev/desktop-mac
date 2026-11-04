## Implementation

- [x] Relay offers without a target host until a receiving page accepts the ticket.
- [x] Validate the receiving page and drop coordinates, and return the chosen target and position on commit.
- [x] Cancel unclaimed offers on drag end, source cancellation, expiration, or source departure.
- [x] Exercise drag text fallback and drop coordinates through the native handoff probe.
- [x] Document the drag relay with additive requirements and scenarios.

## Native pointer takeover

- [x] Preserve local drag until native frame exit.
- [x] Capture and track the panel snapshot, including cancellation and asynchronous release.
- [x] Cover native takeover and cross-host transaction with deterministic integration checks.
