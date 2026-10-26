# Move the app to tilrd

## Why
The daemon is now named tilrd. The app must build, bundle, install and authenticate updates using its current name.

## What Changes
- Build the tilrd Cargo package and use tilrd for signed artifacts, installed binaries and feed metadata.
- Accept the tilrd version prefix and reject other binary identities and feed components.
- Use tilrd in local-server commands and recovery paths. Old tilr-server installations require manual reinstallation.

## Impact
- Local server installation, update feeds and release tooling.
- No changes to protocol support, reload compatibility checks or service adoption.
