## Why
The bundled server now uses protocol 1. The application's installation, signed-feed selection and release validation must exercise that protocol and continue rejecting incompatible servers.

## What Changes
- Specify protocol 1 compatibility for the application distribution.
- Exercise protocol 1 installation and signed updates, including rejection of other protocol versions.
- Validate protocol 1 release metadata without changing the pinned server or metadata-driven packaging.

## Impact
Application server integration and release tests; the server and plugin remain independently released.
