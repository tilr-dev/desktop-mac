# Run desktop CI on release branches

## Why
Release branch fixes need the same CI coverage as changes targeting main so release pull requests can require the mac check.

## What changes
- Run the CI workflow for pull requests targeting main or release/** and pushes to those branches.
- Preserve the mac job and the existing merge queue and manual triggers.

## Out of scope
- Configure the release branches ruleset after this workflow change is merged.
