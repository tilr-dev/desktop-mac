## Design
ServerInstallation owns the marker check and requires a confirmation callback for an unmarked installation. Refusing returns before commands or filesystem writes. Resolve symlinks when comparing marker paths, and restrict automatic authorization to the application installation directory.

Server removal unregisters ordinary startup using the bundled CLI, removes the selected daemon, and cleans the app-installed client and installation metadata only for an app-owned pair. State, tokens, logs and live sessions remain shared resources. Errors prevent subsequent application cleanup and trashing.

Application uninstall uses an injected cleanup/trash coordinator so tests operate only on isolated fixtures. The UI confirms application uninstall, applies the same daemon consent policy, stops application resources, removes application-owned data, moves the bundle to Trash, and quits. Declining daemon removal during uninstall preserves it while allowing application removal.
