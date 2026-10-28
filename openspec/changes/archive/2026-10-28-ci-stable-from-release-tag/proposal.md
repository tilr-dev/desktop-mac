## Why
Merging a release PR creates a stable tag but currently leaves stable application artifacts unpublished. Stable must be built from that tag with the same signing and verified publication guarantees as candidates.

## What Changes
- Build both stable architectures from the release-please tag in the existing Release workflow.
- Allocate a build above all published stable and beta builds, reject previously published stable releases, and publish immutable downloads before appcasts.
- Validate manifest-selected DMGs before CDN writes and attach them to the regular GitHub Release.
- Keep local stable publication disabled.

## Impact
Release workflow, CI release helper, release documentation and release-publishing/release-packaging specifications.
