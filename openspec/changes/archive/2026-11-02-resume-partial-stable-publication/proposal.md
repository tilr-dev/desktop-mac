## Why
A partially published stable build is rejected before the immutable publisher can verify and resume it. This leaves one architecture or the GitHub DMGs unpublished after a transient failure.

## What Changes
- Allow stable publication to resume the same completed build with identical bytes.
- Preserve rejection of existing GitHub assets, newer published builds and conflicting bytes before mutations.
- Document retrying the publish job and the effect of rebuilding all jobs.

## Impact
CI release helper, publication integration tests, release-publishing specification and production instructions.
