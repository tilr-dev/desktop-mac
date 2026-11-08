# Removing Tilr and its local server

Open **Tilr → Local Server… → Remove Local Server…** to remove tilrd. If Tilr installed the server, **Remove the local server?** asks for confirmation: **Cancel** leaves the executables, startup registration and running server unchanged; **Remove** deletes the installed pair and startup registration. The dialog explains that the running server remains until it exits and existing state, token and logs are kept. Otherwise **Remove tilrd?** asks for consent: **No** keeps the installation and integration unchanged; **Yes** unregisters startup and removes the selected tilrd executable. Independently installed terminal clients are kept.

Choose **Tilr → Uninstall Tilr…** to remove the application. After confirmation, Tilr uses the same server policy, stops its own resources, deletes its settings, plugins, web data, caches and preferences, moves its bundle to Trash, and quits. Choosing **No** for an independently installed tilrd still uninstalls the application. Custom configuration and probe instances cannot invoke application uninstall.

Both commands preserve shared daemon state, tokens, logs and already running terminal sessions. Removing startup registration does not stop the running daemon: it remains available until it exits, and a later application launch can attach to it. Moving Tilr to Trash manually also leaves tilrd running; macOS provides no application deletion hook here.

An uninstall error is shown in a dialog and the application stays open. Earlier successful removal steps may already have completed.
