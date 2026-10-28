# Align server release version validation

## Why
The coordinator accepts shortened release versions that the acquisition command rejects later. Both entry points should reject invalid versions before any release work.

## What Changes
- Require the same numeric X.Y.Z version format in both server release commands.
- Remove the redundant bundle preview check and its unused parameter; completed-artifact validation already rejects preview receipts.

## Impact
- Server release argument validation and application bundle assembly.
