# Tilr.app

Tilr hosts each application in a separate native macOS window. Each window runs its own full application page and native plugin session. Windows of the same app share the instance's website storage.

Use **Apps → New Window** (cmd+N) or **New Window** in the command palette (cmd+shift+P) to open another window of the current app. Selecting an app in Apps, ctrl+alt+1..9, ctrl+alt+left/right, or Control `switch` focuses an existing window of that app or opens one. The Apps checkmark follows the key window. The window title and the Apps menu show its stable host UUID; lifecycle logs include the same UUID.

Presentation commands affect the key window: window, frameless, fullscreen, always-on-top, all-desktops and next-desktop. Performance and instance storage remain shared. Dock's application-wide Space assignment still applies to every window; moving one window to another desktop is unavailable while that assignment is All Desktops.

The open window set is saved atomically in `windows.json` in the instance's configuration folder. Restart restores host UUIDs, applications, desktop frames, screens, modes, always-on-top and available desktop Spaces. Disconnected screens fall back to a reachable display. Closing one window releases only that window's page, SSH agent streams and providers. Closing the final window quits as before and keeps it for the next launch.

`window:` settings provide defaults for new windows; reloading configuration preserves existing window state. Legacy `switch.duration`, `switch.easing`, `switch.preload` and Control `slide` inputs remain accepted; switching native windows is immediate and there are no hidden app tabs to preload.

For an isolated development instance, use `./run.sh --test`. `./run.sh --test --probe` exercises page plumbing, native providers, independent duplicate windows, workspace restoration, geometry, menus and desktop movement. It never restarts the production instance. The native-plugin harness also runs the probes in a temporary signed bundle with `python3 scripts/test_native_plugins.py --gui`.
