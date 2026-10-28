## ADDED Requirements

### Requirement: Server release version format
Both server release commands SHALL accept only numeric versions with exactly three dot-separated components (X.Y.Z), validating the version before acquisition or other release work.

#### Scenario: Reject shortened versions before acquisition
- **WHEN** release_server.py or release_server_all.py receives --version 0.2 or --version 0
- **THEN** argument validation exits unsuccessfully before creating release directories, acquiring artifacts or printing a preview plan

#### Scenario: Accept a full version
- **WHEN** either command receives --version 0.2.1 with a positive build and valid protocol version
- **THEN** version validation permits the acquisition or preview flow
