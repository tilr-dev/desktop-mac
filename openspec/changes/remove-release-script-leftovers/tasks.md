## 1. Release scripts
- [x] 1.1 Remove `--public-key` and the `public_key` receipt field from `fetch_server.py` and the release workflow.
- [x] 1.2 Remove `--build` from `ci_release.py build`; keep the stable republication check.
- [x] 1.3 Remove the unused `shutil` import in `release.py` and the unused `tools` parameter of `sparkle_public_key`.
- [x] 1.4 Drop the stale server update sentence from PRODUCTION.md.

## 2. Validation
- [x] 2.1 Update tests for the removed paths and run the script tests.
