## Why
The app and terminal client need to share one ordinary local daemon, including offline first installation, instead of maintaining separate services and credentials.

## What Changes
- Discover the default running server, login-shell PATH installation, then ~/.local/bin.
- Install the bundled signed daemon and client only when no installation exists; use the ordinary service and token commands.
- Bundle the client from the same verified upstream release archive as the daemon.
- Remove the private application service and state directory; existing private installations require reinstallation.

## Impact
Local server installation, credentials, replacement paths, release acquisition and packaging, and deterministic integration fixtures.
