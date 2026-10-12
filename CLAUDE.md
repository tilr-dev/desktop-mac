# Tilr for Mac

WKWebView shell: one window, a tab per app from the config (no tab bar, switched by shortcut),
each a folder served as `tilr://<name>/`.
The page's web views (the `webviews` service of the web repo, a plugin's browser window) are
WKWebViews supplied by the separately compiled `browser-webkit` plugin
(`../../native-plugins/Sources/BrowserWebKit`), in an AppKit SDK overlay of their
own, ordered and masked (holes) as the page stacks their hosts: a float over a browser tile shows.
Native audio also lives in `../../native-plugins`. This app depends only on the SDK's
Objective-C ABI headers; never add provider implementations back to this target. Generic
native placement belongs in `TilrPluginViews`, not the browser engine. See
[native plugin SDK, installation and lifecycle](../../native-plugins/README.md).
`NativePlugins.swift` loads signed versioned packages and owns per-tab sessions. Native
updates take effect after restart. Package/ABI checks: `python3 scripts/test_native_plugins.py`;
add `--gui` in a desktop session for the browser/app probes.

Swift Package, AppKit, no Xcode project. `./run.sh` builds and starts the app; `./run.sh --probe`
runs the self-check (page, palette, app switching, Space move) and quits — run it after changes,
as `./run.sh --test --probe`. The config folder (`~/Library/Application Support/dev.tilr.mac`, or `--config DIR` / `TILR_CONFIG`)
names an instance (`Sources/Tilr/Instance.swift`): another folder is another app running beside
the user's, with its own config, control socket, web storage, pid file and window title.

Desktop modes share the last window frame: switching window / frameless / fullscreen restores
the user's desktop size and position. `window.inset` chooses the initial frame only.
In frameless mode the top `window.drag_height` points move the window using AppKit's drag;
the `window.resize_border` perimeter is reserved for resizing. A click still reaches the
header's clock. `--probe` asserts frame restoration and the header / resize hit boundaries.

## Rules

- Every tunable goes into the config, never as a literal in code: durations, sizes, margins,
  shortcuts, modes, names. Add it to `Config.defaultText` in `Sources/Tilr/Config.swift` with a
  comment saying what it does and its unit, add the field to the `Config` struct, read it from
  `config`. The app writes that text to `default.yml` in the config folder on every launch; the user
  overrides keys in `config.yml` next to it (Sublime model: defaults + overrides, maps merged key
  by key, lists and values replaced whole). Never put defaults into `config.yml` or into the code.
- A setting applies on config reload (the file is watched) unless its comment in the defaults
  says "at launch".
- Keep `./run.sh --probe` passing; extend it when a feature can be checked from code.
- **Testing**: Test in a separate instance: `./run.sh --test` (config `~/Library/Application Support/dev.tilr.mac.test`, its own
  socket, storage and window). Test bundles use the production bundle identifier plus `.test` so they do not inherit the user’s Dock “Assign To” setting. Never restart or kill the user's Tilr for a check; the user's
  instance is restarted only by the user or on their explicit ask. Drive the test instance with
  `tilr ctl --socket ~/Library/Application Support/dev.tilr.mac.test/control.sock …` or `TILR_CONTROL=…`.
- **Private API**: Public API by default. A private/underscored API (`_foo`, `CGS*`,
  `@_silgen_name`) is allowed only when there is no public way, the feature is optional, the call
  is guarded (`responds(to:)`, result checked) and degrades to a public fallback or an honest
  "unavailable". Every use is listed below; check the list on each macOS release.

  | File | Symbol | Feature | Fallback |
  |---|---|---|---|
  | `Shell.swift` | `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`; `SLSBridgedMoveWindowsToManagedSpaceOperation.initWithWindows:spaceID:` / `performWithWMBridgeDelegate` (symbol/class/method/ABI guards); `CGSMoveWindowsToManagedSpace` only before macOS 14.5 | `next-desktop`, `--probe` round trip | explicit unavailable on unsupported systems; async result verified by exact desktop membership, timeout reports failure; no SIP changes |
  | `../../native-plugins/Sources/BrowserWebKit/BrowserAutomation.swift` | `WKWebView._simulateMouseMove:` (`NSSelectorFromString`, `responds(to:)`) | native browser hover; enabled by `browser.automation_private_input` | explicit unavailable error; click uses public AppKit input, scroll uses DOM `scrollBy` |
  | `Debug.swift` | `WKWebView._webProcessIdentifier` (`NSSelectorFromString` + `responds(to:)`, `value(forKey:)`) | debug mode's sampler and demand-driven Performance bridge: WebContent pids | legacy debug: every WebContent process by name; Performance: unavailable (never includes unrelated apps) |

- To see and drive the running app, use Tilr Control (`Sources/Tilr/Control.swift`): `tilr ctl
  snapshot PATH`, `tilr ctl console`, `tilr ctl call SERVICE.METHOD …` (the CLI of the web repo),
  or the `tilr` MCP server. After a Swift change, check it in the test instance (`./run.sh --test`).
