## 1. Specification
- [x] Describe shared daemon discovery, ordinary installation and paired release artifacts.

## 2. Implementation
- [x] Replace private daemon bootstrap with discovery and ordinary service installation.
- [x] Use default daemon state and token credentials; retain session-preserving replacement.
- [x] Acquire and bundle the matching verified tilr client.

## 3. Validation
- [x] Cover discovery order, existing installations, offline installation and shared credentials with integration fixtures.
- [x] Cover matching bundled client and daemon and invalid upstream artifacts.
- [x] Review the complete diff and run required checks.
