## Why
Release candidates must be checked on a Mac before the same artifacts are promoted to stable. Direct publication to stable bypasses that verification, and per-channel build selection can prevent promotion.

## What Changes
- Publish CI releases only to beta with an explicit RC number, an immutable RC tag and a GitHub pre-release.
- Resolve builds across stable and beta for both architectures while keeping numeric marketing versions.
- Reject direct local stable publication, including saved upload selections, without an override.
- Document RC verification followed by promotion of unchanged artifacts.

## Capabilities
### Modified Capabilities
- `release-publishing`: CI RC publication and rejection of direct stable publication.
- `release-packaging`: separate build and publication with stable restricted to promotion.

## Impact
Release workflow, Python release tools and tests, and production documentation. Promotion is implemented separately.
