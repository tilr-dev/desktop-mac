# Remove leftovers of the old release path from release scripts

## Why
After release moved to CI, some script code only looks like it protects something. The upstream server acquisition records and compares a `public_key` that was once the server feed signing key; CI now passes the Sparkle key, so the comparison checks nothing. The `build` numbering command still accepts an explicit build that CI never passes, and its tests cover behavior the specification no longer describes. A few unused imports and parameters remain from the removed local release commands. They mislead anyone editing the release scripts.

## What Changes
- `fetch_server.py` no longer takes `--public-key` and no longer writes `public_key` into the server `release.json` receipt; the release workflow stops passing it.
- `ci_release.py build` no longer takes `--build`: the build is always the highest published build across stable and beta plus one. Stable publication still refuses a build not greater than the published maximum.
- Unused `import shutil` in `release.py` and the unused `tools` parameter of `publish.sparkle_public_key` are removed.
- PRODUCTION.md drops a stale sentence about server updates in the Sparkle delta section.

No requirement changes: the specification does not mention the server public key or an explicit build for the numbering command.

## Impact
Release scripts, the release workflow, their tests and operator documentation.
