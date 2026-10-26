# Update the gitpm Swift integration

## Why
The Swift service still calls an older gitpm API. Regenerated bindings remove replacement confirmation and switch-back methods, and expose package records instead of plugin records, so the app no longer compiles against the current library.

## What Changes
- Update the service and plugin-manager probe to the current package API.
- Replace providers without confirmation and restore the original through replacement by itself.
- Pin CI to the reviewed development commit while continuing to generate bindings locally.

## Impact
- Affected specs: app-control (added replacement integration requirement).
- Affected code: Gitpm service, plugin-manager host/probe, gitpm pin.
