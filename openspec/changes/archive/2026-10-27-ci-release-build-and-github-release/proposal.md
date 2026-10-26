# CI release numbering and GitHub publication

## Why
CI runners have no local release history. Requiring a manually chosen build and leaving release artifacts only on the CDN makes a release unnecessarily manual.

## What Changes
- Resolve one app build from the highest published build on both architectures of the selected channel, unless an explicit higher build is supplied.
- After CDN publication, create an immutable version tag on the build commit and a GitHub Release with both original DMGs and the supplied notes.
- Keep repository write permission only in the publish job and leave local release numbering unchanged.

## Impact
- Release workflow, CI release helpers and tests, and production instructions.
- Modify Release from CI in release-publishing.
