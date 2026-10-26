## Implementation

- [x] Add the Release workflow with server, app and approved publish jobs.
- [x] Import Apple keys into a temporary keychain after compilation; remove it in every outcome.
- [x] Accept a Sparkle private key file and check its public key; drop the Sparkle key from build-only preflight.
- [x] Reuse a published pinned server instead of rebuilding it.
- [x] Cover the workflow contract, key file, preflight and server reuse with tests; run them in CI.
- [x] Document the CI release and its secrets in PRODUCTION.md.
