## 1. Specification
- [x] 1.1 Specify bundle-only bootstrap, update on launch, protocol-only compatibility and latest-stable acquisition.

## 2. Application
- [x] 2.1 Install the bundled pair without a bundled manifest, verifying signatures and matching versions.
- [x] 2.2 Run tilrd update for the selected channel after launch and recheck readiness without blocking startup.
- [x] 2.3 Report protocol mismatches as update Tilr or update tilrd; remove the pin comparison.

## 3. Release
- [x] 3.1 Acquire the latest stable tilrd release and its protocol; remove server-release.json and the bundled manifest and Info.plist pin keys.
- [x] 3.2 Remove the PR CI pin check and document the new flow.

## 4. Validation
- [x] 4.1 Deterministic tests for launch update (newer, equal, unreachable, beta, other protocol) and latest-stable acquisition.
- [x] 4.2 Verify checks and review the final diff.
