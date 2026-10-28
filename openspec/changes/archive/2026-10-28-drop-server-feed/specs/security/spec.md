## MODIFIED Requirements

### Requirement: Private vulnerability reporting
The project SHALL receive vulnerability reports privately through GitHub security advisories at https://github.com/tilr-dev/desktop-mac/security/advisories/new rather than public issues.

#### Scenario: Submit a report
- **WHEN** a reporter submits a security issue
- **THEN** the report includes Tilr version from About, macOS version, architecture and reproduction steps
- **AND** update serving/replacement/signing vulnerabilities (CDN Sparkle/EdDSA and bundled upstream server artifacts) and page-sandbox escapes into native code (bridges, native plugins, Control) are in scope
- **AND** fixes target the latest release only
