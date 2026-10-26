## Why

Releasing the independent macOS server currently requires several manual commands and can accidentally build an unrelated checkout. A single command should prepare the requested tag and stop for inspection before publication.

## What Changes

- Add a server release command accepting version, build, minimum app build, and a tilrd tag.
- Prepare detached tagged sources, validate the protocol, preflight access, build both signed and notarized architectures, and display the artifacts.
- Require explicit confirmation before publishing, verify both public feeds, and print the app pin.
- Support credential-free preview and document the workflow.

## Capabilities

### Modified Capabilities
- release-packaging: add one-command independent server releases.

## Impact

Python release tooling, integration tests, and production documentation.
