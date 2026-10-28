# Release from tags

## Why
Stable desktop releases need an explicit tag approval independent of commit-message conventions. Release history belongs in GitHub Release notes.

## What Changes
- Adopt the pinned shared tag selection workflow for RC branch pushes and stable tag pushes.
- Build and publish the selected tag using tag/version/is_rc outputs.
- Remove automated repository version/changelog maintenance and document tag approval.

## Impact
- Release workflow, CI release helpers, release documentation and deterministic tests.
- Modify release-packaging and release-publishing requirements listed in the accompanying deltas.
