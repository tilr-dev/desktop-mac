## Implementation
- [x] Define the CI triggers, the parallel jobs and the aggregate mac check.
- [x] Split `.github/workflows/ci.yml` into parallel jobs with the aggregate `mac`, Intel only outside pull requests, `.build` caches, no push to main, a nightly run.
- [x] Cover the workflow contract with tests.
