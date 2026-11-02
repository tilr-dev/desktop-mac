## ADDED Requirements

### Requirement: Native layout handoff relay
The shell SHALL relay revisioned one-use handoff offers between trusted loaded pages of the same application, bind acknowledgements to the target page, commit successful transfers and cancel on error, expiration or page departure. The bridge SHALL expose only Control socket `shell list` for choosing a target.

#### Scenario: Real-page transfer
- **WHEN** a trusted page sends `handoff.offer {ticket, payload, targetHost}` and the target restores `handoff.accept {ticket, payload}` and acknowledges it
- **THEN** the source receives `handoff.commit {ticket}` and the target retains the restored window

#### Scenario: Probe waits for runtime initialization
- **WHEN** either page finishes navigation before its asynchronous runtime boot completes
- **THEN** the handoff probe waits for runtime publication and the layout service on both pages before moving a window
- **AND** a navigation failure or readiness deadline fails the probe explicitly instead of continuing with an unready page
- **AND** the standalone handoff probe uses a composed runtime site; the general native GUI probe remains usable with the legacy site

#### Scenario: Page disappears
- **WHEN** the target closes or navigates before acknowledgement
- **THEN** the relay sends `handoff.cancel` to surviving pages, rejects the initiating call and rejects late acknowledgements

#### Scenario: Untrusted origin or other application
- **WHEN** an embedded page, foreign origin or another application's host attempts a transfer
- **THEN** the relay rejects it without dispatching the payload


#### Scenario: Commit completion lease
- **WHEN** both commit event callbacks finish but the source has not confirmed its shared-store decision with `handoff.finalized`
- **THEN** the relay retains the pending lease and cancels provisional windows on page departure or expiration
- **AND** it never replies to an already resolved offer a second time
