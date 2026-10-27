## Why
Development builds currently inherit a release-looking template version, and workspaces written by older gitpm versions can retain inactive plugins in dist until explicitly synchronized.

## What Changes
- Stamp development bundles from the latest reachable v-tag and current commit, with a dirty suffix for tracked changes.
- Keep a development placeholder in the source plist and require an explicit initial release version when no numeric history exists.
- Synchronize the configured plugin workspace once at startup, logging success or failure without aborting launch.

## Capabilities
### Modified Capabilities
- `development`: development bundle version stamping.
- `release-packaging`: placeholder-aware release numbering.
- `app-control`: startup migration of plugin distribution contents.

## Impact
run.sh, release coordinator, plugin manager service/host, launch wiring, probes and release documentation. The pinned gitpm version is preserved.
