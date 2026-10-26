# Release Tilr from CI

## Why
Releases are built and published only from the release Mac (`release.command`, local Keychain, notarytool profile, Sparkle key, Wrangler login). Dan decided that Tilr is built, signed, notarized and published from CI on GitHub-hosted macOS, with Sparkle signing in an approved publish job (decision 2026-10-16; TILR-544).

## What Changes
- A manual `Release` workflow with three jobs: server (reuse the published pinned server or build, sign and notarize it), app (build, sign, notarize, package both DMGs), publish (after approval in the `release` environment, publish the tested artifacts unchanged).
- Apple keys are imported into a temporary keychain after compilation and removed at the end of the job; the notarytool profile uses an App Store Connect API key.
- Sparkle tools accept a private key file on an unattended runner (`TILR_SPARKLE_KEY_FILE`); its public half is checked against the configured key.
- A build-only preflight no longer requires the Sparkle private key.
- `fetch_server.py` reuses an already published pinned server instead of rebuilding it.

## Impact
- Specs: release-publishing (credential preflight, deltas, new CI release requirement), release-packaging (separate build and publication, release numbering).
- Local release commands keep their behaviour.
