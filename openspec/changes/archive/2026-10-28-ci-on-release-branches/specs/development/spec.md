## ADDED Requirements

### Requirement: CI coverage for main and release branches
The CI workflow SHALL run the mac job for pull requests targeting main or release/** and pushes to main or release/**.

#### Scenario: Pull request targets a release branch
- **WHEN** a pull request targets release/0.1 or another branch matching release/**
- **THEN** CI runs the mac job

#### Scenario: Push updates a release branch
- **WHEN** a commit is pushed to a branch matching release/**
- **THEN** CI runs the mac job

#### Scenario: Main retains CI coverage
- **WHEN** a pull request targets main or a commit is pushed to main
- **THEN** CI runs the mac job
