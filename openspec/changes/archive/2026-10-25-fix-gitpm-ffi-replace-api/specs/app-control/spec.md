## ADDED Requirements

### Requirement: Package replacement integration
The app's gitpm service SHALL use the pinned package-manager API for replacement without confirmation, preserving structured incompatibility errors, and SHALL restore the original provider by replacing it with itself.

#### Scenario: Reject an invalid replacement
- **WHEN** the plugin-manager probe attempts replacement with a package that does not declare the original in its replacements
- **THEN** the service returns the library's structured invalid-argument error

#### Scenario: Refuse an incompatible provider
- **WHEN** an installed consumer does not accept the version provided by a proposed replacement
- **THEN** replacement fails with `incompatible_replacement` and identifies the consumer
- **AND** the consumer keeps its previous provider

#### Scenario: Restore the original provider
- **WHEN** a replacement is active and the service replaces the original with itself
- **THEN** consumers resolve to the installed original again
- **AND** the operation requires no confirmation parameter
