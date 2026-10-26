## 1. Specification
- [x] Add the merge readiness diagnostics requirement and scenarios.

## 2. Implementation
- [x] Use the shared trusted merge-fetch helper maintained in gitpm.
- [x] Document trusted deployment and required permissions.

## 3. Validation
- [x] Cover pending, conflict, stale API heads and command failures with deterministic fixtures in the shared helper.
- [x] Verify shared helper deployment without component-local copies.
