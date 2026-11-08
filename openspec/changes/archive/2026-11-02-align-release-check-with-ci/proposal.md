## Why
The access-check scenario names a flag that CI never invokes, and three scenario titles still refer to removed local release commands. The normal CI packaging invocation already performs build preflight before packaging.

## What Changes
- Describe build preflight at the start of CI packaging and remove the separate `release_all.py --check` mode and its test.
- Rename packaging and numbering scenarios to describe their existing CI behavior, preserving their bodies.

## Capabilities
### Modified Capabilities
- `release-publishing`: align credential preflight with the CI packaging invocation.
- `release-packaging`: align scenario titles with CI packaging, stable selection and build allocation.

## Impact
Only the packaging CLI, its tests and release specifications change. CI continues using the existing packaging invocation.
