## 1. Specification
- [x] Release from CI runs only from release/X.Y.
- [x] Specification checks name main instead of the removed development branch.

## 2. Implementation
- [x] Refuse a non-release ref in a first job without keys; every job with keys waits for it.
- [x] Download the shared checker scripts from an immutable gitpm commit with the same digests.
- [x] Replace the remaining references to the development branch in workflows, gitpm.pin and documentation.

## 3. Validation
- [x] Cover the branch check for release branches, main and other refs, and the job order, with deterministic tests.
- [x] Validate the release workflow and specification.
