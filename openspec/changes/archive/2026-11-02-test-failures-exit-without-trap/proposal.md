## Why

Expected test and probe failures currently trigger traps, crash reports and macOS crash notifications. Failed checks need actionable diagnostics and an ordinary unsuccessful process exit.

## What Changes

- Share a Swift test failure helper that writes source-located diagnostics to stderr and exits with status 1.
- Give every application probe the same clean failure behavior with its probe prefix.
- Preserve subprocess diagnostics in Python test runners and document the rule.

## Impact

Successful checks keep their existing behavior. Failed checks remain failures in local checks and CI without deliberate crashes.
