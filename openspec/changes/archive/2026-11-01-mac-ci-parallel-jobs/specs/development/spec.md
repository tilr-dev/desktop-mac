## MODIFIED Requirements

### Requirement: CI coverage for main and release branches
The CI workflow SHALL run the mac check for pull requests targeting main or release/**, for merge queue groups, for pushes to release/**, on manual dispatch and nightly on main. A push to main SHALL NOT start CI: the merge queue has already checked the merged result.

#### Scenario: Pull request targets a release branch
- **WHEN** a pull request targets release/0.1 or another branch matching release/**
- **THEN** CI runs the mac check

#### Scenario: Push updates a release branch
- **WHEN** a commit is pushed to a branch matching release/**
- **THEN** CI runs the mac check with the Intel build

#### Scenario: Main retains CI coverage
- **WHEN** a pull request targets main or the merge queue checks a group for main
- **THEN** CI runs the mac check

#### Scenario: Push to main does not repeat CI
- **WHEN** the merge queue merges a group into main
- **THEN** the push to main starts no CI run

#### Scenario: Nightly run on main
- **WHEN** the nightly schedule fires
- **THEN** CI runs the full mac check on main, including the Intel build

## ADDED Requirements

### Requirement: Parallel mac CI jobs with an aggregate mac check
The CI workflow SHALL run probe, release script tests, native plugin tests, app tests and the Intel (x86_64) build as parallel jobs, and an aggregate job named mac that the main ruleset requires. The mac job SHALL run whatever the other jobs end with and SHALL fail unless each of them succeeded; only the Intel build may be skipped, and only on pull requests. The Intel build SHALL run on every event except pull requests.

#### Scenario: A parallel job fails
- **WHEN** any of the parallel jobs fails or is cancelled
- **THEN** the mac job runs and fails

#### Scenario: Pull request skips the Intel build
- **WHEN** CI runs for a pull request and the other jobs succeed
- **THEN** the Intel build is skipped and the mac job succeeds

#### Scenario: Merge queue builds Intel
- **WHEN** CI runs for a merge queue group, a release branch push, a manual dispatch or the nightly schedule
- **THEN** the Intel build runs, and the mac job fails if it was skipped

### Requirement: Cached SwiftPM builds in CI
Each CI job that builds Swift packages SHALL restore SwiftPM's download cache and its `.build` directory, keyed by the job, the runner, the Swift toolchain and the `Package.resolved` files, so a pull request with a warm cache rebuilds only what changed. Nightly, manual and release branch runs SHALL save `.build` under their commit; pull requests and merge queue groups SHALL only restore it.

#### Scenario: Toolchain changes
- **WHEN** the runner image ships a different Swift toolchain
- **THEN** the `.build` cache key changes and the job does not reuse build products of the old toolchain

#### Scenario: Main moves on
- **WHEN** the nightly run builds a newer main than the cached `.build`
- **THEN** it saves a new `.build` cache, and later pull requests restore the newest one
