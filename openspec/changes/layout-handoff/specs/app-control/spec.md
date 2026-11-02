## ADDED Requirements

### Requirement: Native layout handoff relay
The shell SHALL relay revisioned one-use handoff offers between trusted loaded pages of the same application, bind acknowledgements to the target page, commit successful transfers and cancel on error, expiration or page departure. The bridge SHALL expose only Control socket `shell list` for choosing a target.

#### Scenario: Real-page transfer
- **WHEN** a trusted page sends `handoff.offer {ticket, payload, targetHost}` and the target restores `handoff.accept {ticket, payload}` and acknowledges it
- **THEN** the source receives `handoff.commit {ticket}` and the target retains the restored window

#### Scenario: Page disappears
- **WHEN** the target closes or navigates before acknowledgement
- **THEN** the relay sends `handoff.cancel` to surviving pages, rejects the initiating call and rejects late acknowledgements

#### Scenario: Untrusted origin or other application
- **WHEN** an embedded page, foreign origin or another application's host attempts a transfer
- **THEN** the relay rejects it without dispatching the payload
