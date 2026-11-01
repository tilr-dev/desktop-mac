# Run mac CI as parallel jobs

## Why
The mac check ran as one sequential job of about eight minutes, and it ran three times per change: on the pull request, in the merge queue and again on the push to main. Pull requests felt slow, and the push to main repeated a run the queue had just passed.

## What Changes
- Split the mac job into parallel jobs (probe, release script tests, native plugins, app tests, Intel build) and keep `mac` as the aggregate job the main ruleset requires; it fails when any job fails or is cancelled.
- Build Intel (x86_64) only in the merge queue, on release branch pushes, on manual and nightly runs; pull requests skip it.
- Cache SwiftPM's `.build` per job, keyed by the toolchain and `Package.resolved`, next to the SwiftPM download cache.
- Drop the run on pushes to main and add a nightly full run on main.

## Impact
`.github/workflows/ci.yml` and its contract test in `scripts/test_release_workflow.py`. Commands of the test steps are unchanged.
