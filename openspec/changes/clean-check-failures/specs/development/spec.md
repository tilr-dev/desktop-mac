## ADDED Requirements

### Requirement: Clean test and probe failures
Swift test scripts and application probe modes SHALL report failed checks through stderr and exit status 1, without using precondition, preconditionFailure, fatalError or assert to report a failed check.

#### Scenario: Swift test check fails
- **WHEN** a check in scripts/test_*.swift fails
- **THEN** a shared helper writes `FAIL <file>:<line>: <message>` to stderr and exits with status 1
- **AND** the failure does not deliberately raise a trap or produce a crash report

#### Scenario: Application probe fails
- **WHEN** any application probe detects a failed check
- **THEN** it writes a diagnostic prefixed with its probe name to stderr and exits with status 1
- **AND** the failure does not deliberately raise a trap or produce a crash report

#### Scenario: Python runner receives a failure
- **WHEN** a Swift test process or application probe exits unsuccessfully
- **THEN** its Python runner reports failure and exposes the process stderr
- **AND** local checks and CI remain unsuccessful
