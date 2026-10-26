## 1. Specification
- [x] Describe automatic CI numbering and GitHub publication under Release from CI.

## 2. Implementation
- [x] Resolve the build once from both channel appcasts and pass it explicitly to build and publish commands.
- [x] Create a version tag and GitHub Release after CDN publication with both original DMGs and notes.
- [x] Document CI inputs, outputs and existing-tag behavior in PRODUCTION.md.

## 3. Validation
- [x] Cover numbering, feed failures, workflow wiring, GitHub publication and existing tags with deterministic tests.
- [x] Validate the release workflow and specification.
