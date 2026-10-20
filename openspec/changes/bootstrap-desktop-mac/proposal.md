## Why

desktop-mac has no OpenSpec baseline. Existing contracts are spread across contributor, release, production, security and native-plugin documentation, with application behavior additionally described in Sources. Intake and review need a capability-based specification to compare changes against.

## What Changes

- Establish an OpenSpec baseline of the existing desktop application, developer workflow, packaging and publishing contracts.
- Preserve the original documents as operational guides and record their coverage in `design.md`.
- Add only new requirements; do not change application behavior or the workflow repository's checks.

## Capabilities

### New Capabilities
- `configuration`: settings, defaults, reload and instance isolation.
- `app-shell`: window modes, menus, palette, tabs and Spaces.
- `site-serving`: local app origins, assets, navigation and hot reload.
- `app-control`: JSON control socket and page service calls.
- `performance`: shared web collector and native sampling/export bridges.
- `local-server`: managed server installation, credentials and independent updates.
- `native-plugins`: native package ABI, trust, lifecycle and bundled providers.
- `release-packaging`: build, sign, notarize and verify distributable artifacts.
- `release-publishing`: independent app/server release feeds and publication.
- `development`: supported tooling, local builds and verification workflow.
- `security`: distribution and runtime trust boundaries.

### Modified Capabilities
None.

## Impact

Documentation only, under `openspec/`. No source, binary, default setting, external protocol or dependency changes. The task's `bin/finish` archives this change and creates `openspec/specs/` from its ADDED requirements.
