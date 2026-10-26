# Bundle the signed upstream server release

## Why
The daemon release already provides signed and notarized macOS executables. Rebuilding it in the desktop repository creates a second binary for the same version and duplicates signing infrastructure.

## What Changes
- Fetch the pinned upstream macOS archive and verify its SHA-256 and Developer ID signature before packaging.
- Use the release version reported by the upstream executable in completion metadata and offline installation checks.
- Replace server compilation/signing in CI and local release commands with acquisition of the same completed release; retain independent feed publication.

## Impact
- Release packaging, CI release publication, and offline server bootstrap.
- Release scripts and their integration tests.
