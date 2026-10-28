# Remove local release scripts

## Why
Releases now run exclusively in CI. Local release entry points duplicate publication, keep unrelated build reservations and expose a second release path.

## What Changes
- Remove local release commands, setup, server acquisition wrappers and local build history.
- Keep CI packaging and shared immutable publication helpers; publication runs through the CI coordinator.
- Document the CI release and automatic upstream server pin updates.

## Impact
Release packaging and publishing specifications, release scripts, their tests and operator documentation. Development builds and artifact verification remain available.
