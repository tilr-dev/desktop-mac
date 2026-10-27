## 1. Specification
- [x] Describe shared daemon discovery, ordinary installation and paired release artifacts.

## 2. Implementation
- [ ] Replace private daemon bootstrap with discovery and ordinary service installation.
- [ ] Use default daemon state and token credentials; retain session-preserving replacement.
- [ ] Acquire and bundle the matching verified tilr client.

## 3. Validation
- [ ] Cover discovery order, existing installations, offline installation and shared credentials with integration fixtures.
- [ ] Cover matching bundled client and daemon and invalid upstream artifacts.
- [ ] Review the complete diff and run required checks.
