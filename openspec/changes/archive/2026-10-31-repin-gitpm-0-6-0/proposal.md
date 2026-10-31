# Repin the plugin manager to gitpm v0.6.0

## Why
gitpm.pin names the release candidate v0.6.0-rc.1 because the stable release had not been cut when the app moved to gitpm release archives. The stable v0.6.0 is now published on the same commit, and a Tilr release must not link a pre-release plugin manager.

## What Changes
- Pin gitpm v0.6.0: same commit as the release candidate, the SHA-256 of the archive published with the v0.6.0 release (the archive name carries the tag, so the checksum differs from the candidate's).
- No Swift changes: the tag points to the commit already pinned, so the FFI API is identical.

## Impact
The existing release-packaging requirement (Pinned plugin manager release) already covers this path. Only release data changes; no requirements change.
