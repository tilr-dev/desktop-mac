## Why
Tilr needs the same release-branch flow as the other repositories: each fix produces a candidate automatically, and merging the release PR is the release approval.

## What Changes
- Run on pushes to release/** with the pinned shared release-please and RC workflow.
- Obtain the numeric version and candidate tag from the shared workflow, then build and publish both architectures to beta without environment review.
- Attach the unchanged DMGs to the shared GitHub prerelease, preserving its tag and release notes.
- Keep branch restrictions and automatic appcast build numbering; remove manual workflow inputs.
- Document release PR merge as approval and the source of the stable tag. Stable artifact publication is a separate workflow change.

## Impact
- Release workflow, release-please configuration, CI publication helper and integration tests, PRODUCTION.md.
- Modify Release from CI, Persistent release numbering, and Separate setup build and publication.
