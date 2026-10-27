# Runtime RC update preference

## Why
A signed application tied to a publication channel cannot use the same tested DMG for beta and stable distribution.

## What Changes
- Keep the verification key and a runtime-feed-selection marker in the signed app, without a channel-specific feed URL.
- Select the native architecture’s stable or beta appcast before each Sparkle check using a persisted, initially disabled Receive RC versions preference.
- Expose the preference in Update Settings alongside Sparkle automatic check/download choices.
- Validate channel-neutral release bundles while retaining support for completed older artifacts and channel-specific publication receipts and delta histories.

## Impact
- release-packaging: Architecture-specific signed artifacts.
- release-publishing: Immutable publication with feed last; Application updater lifecycle and consent.
- AppUpdates, the app menu, release/verification scripts and release documentation.
