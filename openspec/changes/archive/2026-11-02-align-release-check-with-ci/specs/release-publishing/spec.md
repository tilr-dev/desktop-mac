## MODIFIED Requirements

### Requirement: Credential preflight and secret handling
Release tools SHALL use existing authorized CI credentials without printing secrets, storing them in Git, creating replacement certificates to bypass restrictions or changing blanket key permissions.

#### Scenario: Check release access
- **WHEN** the CI build job runs release_all.py to package a release
- **THEN** it first verifies required build tools, the configured identity/private key, notarization profile, temporary real signing and disk-image creation before packaging, without requiring the Sparkle private key
- **AND** the CI publisher uses scoped Sparkle/R2 access without Apple signing private keys, notarization login, compilation or image creation
- **AND** release configuration comes from the runner environment; no local setup command or local credentials configuration file is required
- **AND** all app architectures share the Sparkle public key, separate from Developer ID credentials; CDN access uses R2 S3 keys through the AWS CLI
- **AND** unattended runners must already possess scoped access without interactive prompts or permission bypasses

#### Scenario: Sparkle key on an unattended runner
- **WHEN** TILR_SPARKLE_KEY_FILE names a Sparkle private key file
- **THEN** Sparkle signing and verification use that file instead of the Keychain account
- **AND** its public key, derived from the file, must equal the configured public key before publication
