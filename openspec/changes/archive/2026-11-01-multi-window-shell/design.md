# Window ownership

A Shell owns one native window and one page. A workspace owns the ordered set of Shells and the key host. Each host is a persisted UUID, separate from the app identity. Duplicate app windows use independent full runtime pages and native sessions while sharing Instance.store and instance profile storage.

Window mode, desktop frame, screen identity, Space membership and always-on-top belong to the host. Window styling and geometry configuration supply defaults when a host is created; configuration reload does not reset a restored or existing host. Debug/Performance, app configuration, the instance Control socket and website storage remain shared. Activation policy and the operating system’s Dock application Space assignment are process-wide; a Dock assignment to all desktops still prevents individual desktop moves.

The key window selects the active app for menus, palette, changed notifications and requests without an explicit app. Switch focuses an existing matching host (prefer the key host), otherwise creates one. New Window always creates another host for the current app. Closing a host releases only that page and its native resources. Closing the final host follows the existing termination policy, preserving the last workspace for the next launch.

Persist host records atomically in the instance configuration directory. Save desktop geometry rather than fullscreen bounds; record screen and Space identifiers where available. Restore valid configured apps only, use a reachable screen when a recorded screen has gone away, and guard private Space operations as before. If no usable saved workspace exists, create one host for the default app. No tab preload or slide work survives.
