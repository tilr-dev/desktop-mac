# Repin the CI server release to tilrd 0.2.0

## Why
The previous server pin refers to an unpublished release whose source tag does not exist. Release CI needs an existing tilrd tag to build the server when its feed is absent.

## What Changes
- Pin tilrd 0.2.0, build 3, protocol version 1.
- Document `server_min_app_build=17` for the first CI release of this server.

## Impact
Existing release-publishing (Release from CI) and release-packaging (Independently built server artifacts) requirements already cover this path. Only release data and operator instructions change; no requirements change.
