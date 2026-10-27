# Safe server removal and application uninstall

## Why
The ordinary daemon is shared with the terminal client. Removal must distinguish an application-installed daemon from one installed independently and obtain consent before removing the latter. Users also need an explicit way to uninstall the application.

## What Changes
- Offer Remove Local Server for discovered installations, automatically authorize marked installations, and ask before removing an unmarked daemon.
- Add Uninstall Tilr… to clean application-owned resources and move the application to Trash using the same server-removal policy.
- Keep ordinary daemon state and existing sessions, and leave the daemon running when the application is dragged to Trash.

## Impact
Local-server management, application menu, and isolated integration fixtures.
