## 1. Specification
- [x] 1.1 Specify the pinned gitpm release installation and its use in CI, candidate and stable builds.

## 2. Release
- [ ] 2.1 Pin a gitpm release tag, its commit and the archive SHA-256 in gitpm.pin.
- [x] 2.2 Add scripts/fetch_gitpm.py: download, verify, safely extract and install the archive.
- [x] 2.3 Use it in ci.yml and release.yml instead of compiling gitpm; remove the Rust toolchain steps.

## 3. Documentation
- [x] 3.1 Describe the artifact and the pin in PRODUCTION.md, CLAUDE.md and the build script comments.

## 4. Validation
- [x] 4.1 Deterministic tests for the fetch: pinned and published checksum, tag commit, unsafe or incomplete archives, missing slices, reuse of an installed release.
- [ ] 4.2 Verify checks and review the final diff.
