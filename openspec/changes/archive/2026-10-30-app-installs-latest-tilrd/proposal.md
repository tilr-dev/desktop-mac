# Keep the installed tilrd on the latest release

## Why
The application pinned one tilrd release and an upstream bot proposed pin bumps. A bump that could not merge without a spec change let a desktop release ship an older server than the latest one, and even a merged bump reached users only with the next application release.

## What Changes
- The bundled tilrd and tilr are the latest stable release when the application is built. They are installed only when no tilrd is installed and are an offline starting point, not a pin.
- At every launch, including the first launch after a Sparkle update, the application runs the selected tilrd's own update command in the background for the Receive RC versions channel. Update tilrd does the same on demand.
- Compatibility is checked only by protocol. A daemon speaking a newer protocol than the application asks the user to update Tilr; an older one asks to update tilrd.
- Release CI acquires the latest stable tilrd GitHub Release and reads its protocol from the released source. server-release.json, the bundled app-managed.json, the TilrBundledServer* Info.plist keys and the PR CI pin check are removed.

## Impact
Local server installation and status, release packaging and publishing specifications, release scripts, CI workflows, their tests and operator documentation.
