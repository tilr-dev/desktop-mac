# Update the local daemon through tilrd

## Why
The ordinary daemon already owns its update mechanism. Maintaining another server feed and binary replacement implementation in the application duplicates that mechanism.

## What Changes
- Run `tilrd update --channel stable|beta` from Local Server, using Receive RC versions.
- Show the installed daemon version and an update prompt for an old version or incompatible protocol, including a daemon just started by the application.
- Preserve the daemon and credentials when an update fails, and leave the update action available.
- Remove application-side server feed consumption and update replacement; retain offline bundled installation and its pair-install journal.

## Impact
- Local Server controls, installation discovery, configuration and integration tests.
- The application update mechanism and server release publication are independent of this change.
