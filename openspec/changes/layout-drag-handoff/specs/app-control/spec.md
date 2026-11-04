## ADDED Requirements

### Requirement: Native layout drag handoff relay
The shell SHALL park untargeted `handoff.offer` tickets until a valid `handoff.accept` selects another current page of the same app and finite layout coordinates. It MUST bind tickets to their source and use acknowledged handoff after selection. Compatibility offers SHALL expire after ten seconds; native pointer offers SHALL remain valid for the held gesture, with the transaction deadline starting on target selection.

#### Scenario: Park an offer until a drop
- **WHEN** a loaded current source page offers a fresh ticket with its host identity, window identity and a valid positive integer revision, without a target host
- **THEN** the relay parks the offer and leaves its reply pending without sending a restore event to another page
- **AND** a duplicate offer for the parked ticket is rejected with `Handoff ticket already used`

#### Scenario: Claim a ticket at the drop position
- **WHEN** a different loaded current page of the same application sends `handoff.accept {ticket, position}` for a parked offer with finite numeric non-boolean `x` and `y`
- **THEN** the relay selects that page's native host, inserts the position into the payload and starts the existing acknowledged handoff transaction
- **AND** the accepting call receives `{accepted: true}`
- **AND** after successful commit callbacks the source offer reply contains `ticket`, `targetHost` and `position`
- **AND** source finalization completes the transaction

#### Scenario: Reject an invalid drop
- **WHEN** acceptance references an unavailable ticket, the source page, a different application, an unloaded or non-current page, or missing or invalid coordinates
- **THEN** the accepting call fails with `Invalid drop or unavailable handoff ticket`
- **AND** it does not claim a parked offer or transfer ownership

#### Scenario: End an unclaimed drag
- **WHEN** the source sends `handoff.dragend {ticket}` while its offer is still parked
- **THEN** the relay cancels the offer with `Drag cancelled`, notifies the source and rejects the pending offer reply
- **AND** the source retains its window and the ticket cannot be reused

#### Scenario: End a claimed drag
- **WHEN** a drop has already claimed an offer before the source sends `handoff.dragend {ticket}`
- **THEN** drag end returns `{accepted: true}` without cancelling the running handoff transaction

#### Scenario: Cancel a parked offer explicitly
- **WHEN** the source sends `handoff.cancel {ticket}` for its parked offer
- **THEN** the relay cancels it with `Handoff cancelled` and returns `{accepted: true}` to the cancellation call
- **AND** the source retains its window and the ticket cannot be reused

#### Scenario: Reject cancellation by another page
- **WHEN** another page sends `handoff.dragend` or `handoff.cancel` for a parked offer
- **THEN** the call fails with `Handoff belongs to another page` and leaves the offer parked

#### Scenario: Expire an unclaimed offer
- **WHEN** an offer remains unclaimed for ten seconds after registration
- **THEN** the relay cancels it with `Handoff timed out`, notifies the source and rejects the pending offer reply
- **AND** the source retains its window and a later drop cannot claim the consumed ticket

#### Scenario: Source page departs before a drop
- **WHEN** the source closes or navigates while its offer is parked
- **THEN** the relay cancels it with `Handoff page closed or navigated` and rejects the pending offer reply
- **AND** a later drop cannot claim the consumed ticket

### Requirement: Native pointer drag takeover
The shell SHALL preserve local header drag until the pointer exits the source native frame, then prepare and snapshot its panel and track the image above other windows. Release over another eligible page SHALL initiate acknowledged handoff. Escape, release elsewhere, snapshot failure or source departure MUST retain the source and remove tracking resources. Asynchronous callbacks SHALL belong to the current gesture.

#### Scenario: Exit and snapshot
- **WHEN** a held pointer first leaves the source native frame
- **THEN** native tracking asks the source page to end local movement, snapshots the prepared panel and follows the screen pointer with the original grab offset
- **AND** movement within the source frame before exit creates no handoff offer or floating snapshot

#### Scenario: Drop during asynchronous preparation
- **WHEN** the pointer is released over an eligible destination before preparation or snapshot completion
- **THEN** the release position is retained and handoff runs once preparation succeeds
- **AND** a failed snapshot cancels the gesture and restores the source

#### Scenario: Cancel and page departure
- **WHEN** Escape is pressed, the pointer is released outside eligible Tilr content, or the source page leaves
- **THEN** tracking monitors and the floating snapshot are removed and the source is retained
- **AND** late snapshot or preparation replies cannot resurrect that gesture or affect a subsequent one

#### Scenario: Long native gesture
- **WHEN** a native gesture remains held beyond the compatibility offer lifetime
- **THEN** it remains eligible for drop without extending any running handoff transaction deadline
