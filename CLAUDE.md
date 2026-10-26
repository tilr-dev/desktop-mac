# Tilr for Mac

WKWebView shell: one window, a tab per app from the config (no tab bar, switched by shortcut),
each a folder served as `tilr://<name>/`.
Tabs are lazy: an app's page, folder watcher and native providers start when it is first
selected, by `switch.preload` (`false` | `true` | seconds after the first page), or by a Tilr
Control command that needs the page (`control.load_timeout`). A hidden tab's container does not
follow window resizes; a switch slides the containers' layers (`layer.transform`), never view frames.
The page's web views (the `webviews` service of the web repo, a plugin's browser window) are
WKWebViews supplied by the separately compiled `browser-webkit` plugin
(`native-plugins/Sources/BrowserWebKit`), in an AppKit SDK overlay of their
own, ordered and masked (holes) as the page stacks their hosts: a float over a browser tile shows.
A reload of the page parks the views made with a `key` (a browser window's id) for
`browser.adopt_grace` seconds; the new page's `create` with that key adopts the live view.
A view wholly under the holes or off the overlay is hidden (no rendering; automation
`evaluate` still answers, click and hover refuse a hidden view); size changes during a live resize reach it every `browser.live_resize_interval` ms.
A view hidden (or parked, in a concealed tab, in an occluded or minimized window) for `browser.discard_after` seconds drops its WKWebView (process exits,
last picture kept, `discarded: true`) and comes back with history and scroll when shown.
Native audio also lives in `native-plugins`. This app depends only on the SDK's
Objective-C ABI headers; never add provider implementations back to this target. Generic
native placement belongs in `TilrPluginViews`, not the browser engine. See
[native plugin SDK, installation and lifecycle](native-plugins/README.md).
`NativePlugins.swift` loads signed versioned packages and owns per-tab sessions. Native
updates take effect after restart. Package/ABI checks: `python3 scripts/test_native_plugins.py`;
add `--gui` in a desktop session for the browser/app probes.

The plugin manager is the Rust library gitpm (`../git/gitpm`, its UniFFI wrapper
`gitpm-ffi`), linked statically: `scripts/build-gitpm.sh` (run by `run.sh` and the release scripts; rebuilds
when the library's sources are newer, needs cargo + rustup targets then) puts
`Vendor/GitpmFFI.xcframework` (C module `GitpmFFI`) and `Sources/Gitpm/Generated/Gitpm.swift` (both
gitignored) in place; the `Gitpm` target's `Sources/Gitpm/PluginManagerService.swift` runs it off the main
thread (async, errors as `PluginManagerFailure` kind + message), `PluginManagerHost.swift` feeds it
`plugin_manager.workspace` (default `<config folder>/plugins`) and `plugin_manager.catalog`
(`https://pkg.tilr.dev`), both on reload. No UI or page bridge yet; `tilr ctl` raw command
`{"cmd":"plugin-manager"}` reads the state, `--probe` exercises it on a temporary workspace.
Launch runs `syncDist` once to migrate the configured workspace's legacy dist contents to active
plugins only; failures are logged and do not abort startup. Missing/empty workspaces are not
created, unmanaged files are preserved, and probes use temporary workspaces.
CI generates bindings from the full commit SHA in `gitpm.pin`; its first field is a
revision label (a tag or `dev`). Local and release builds use `../git/gitpm` or
`GITPM_DIR`, so that checkout must expose the same API as the pin. The service uses
`PackageManager`/`InstalledPackage`; `replace(original:replacement:)` has no confirmation
parameter and refuses incompatible consumers. Restore the original with
`replace(original: id, replacement: id)`. The probe covers invalid replacement,
replacement and restoration of a consumer's provider, and incompatible refusal using local repositories.
The library runs the system `git` for now (git must exist on the machine): install, update,
rollback, restore, fork, version check and auth check first ask `PluginManagerService.gitProblem()` and fail
with kind `git` and a message saying to install the Command Line Tools, instead of running the
`/usr/bin/git` stub (which would pop up the CLT installer); the probe skips its git step then.

Swift Package, AppKit, no Xcode project. `./run.sh` builds and starts the app; `./run.sh --probe`
runs the self-check (page, page plumbing — scheme handler, native events, console relay,
snapshot PNG —, palette, app switching and slide, lazy tabs, Space move) and quits — run it after changes,
as `./run.sh --test --probe`. Development bundles use `<last reachable v-tag>-dev.<commit>[.dirty]`
(base `0.0.0` without tags), build 1; tracked changes add `.dirty`. The source `Info.plist` keeps
`0.0.0-dev`; release scripts stamp real versions. The config folder (`~/Library/Application Support/dev.tilr.mac`, or `--config DIR` / `TILR_CONFIG`)
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
  | `native-plugins/Sources/BrowserWebKit/BrowserAutomation.swift` | `WKWebView._simulateMouseMove:` (`NSSelectorFromString`, `responds(to:)`) | native browser hover; enabled by `browser.automation_private_input` | explicit unavailable error; click uses public AppKit input, scroll uses DOM `scrollBy` |
  | `Debug.swift` | `WKWebView._webProcessIdentifier` (`NSSelectorFromString` + `responds(to:)`, `value(forKey:)`) | demand-driven Performance bridge: WebContent pids | unavailable (never includes unrelated apps) |
  | `Tab.swift` (`WebKitFeatures`) | `+[WKPreferences _features]` → `_WKFeature.key`; `-[WKPreferences _setEnabled:forFeature:]` (BOOL, `@convention(c)` cast of `method(for:)`), read back with `_isEnabledForFeature:` — all `NSSelectorFromString` + `responds(to:)` | `web.high_refresh_rate`: `PreferPageRenderingUpdatesNear60FPSEnabled` off, pages render at 120 Hz on ProMotion; also handed to the browser plugin as `browser.high_refresh_rate` | stays at 60 Hz; logged once, `tilr ctl debug status` → `highRefreshRate: unavailable` |
  | `native-plugins/Sources/BrowserWebKit/WebKitFeatures.swift` (copy of `Tab.swift`'s) | `+[WKPreferences _features]`, `-_setEnabled:forFeature:`, `-_isEnabledForFeature:` (`NSSelectorFromString`, `responds(to:)`, `@convention(c)` cast) | `browser.high_refresh_rate` (from `web.high_refresh_rate`): browser views without WebKit's 60 Hz cap | logged once as unavailable; the views stay at 60 Hz |
  | `Memory.swift` | `WKWebView._inspector` → `_WKInspector.show`; `WKPreferences._setDeveloperExtrasEnabled:` (KVC `developerExtrasEnabled`, set on request only) — all `NSSelectorFromString` + `responds(to:)`, never linked | Performance `{type:'inspector'}`, `tilr ctl debug inspect`: open Web Inspector for the tab's page | `{ shown: false, reason }`; Safari → Develop → Tilr (`isInspectable`) |

- **Memory diagnosis** (`Memory.swift`, Performance bridge `{type:'footprint'|'squeeze'|'inspector'}`,
  `tilr ctl debug footprint|squeeze|inspect`): `footprint` runs `/usr/bin/footprint -j` (public tool,
  off the main thread, `debug.footprint_timeout`) on the tab's WebContent processes and Tilr and
  reports malloc / graphics / js / jit / other. `squeeze` posts the Darwin notification
  `org.WebKit.lowMemory` (public `notify_post`): it is **system-wide** — every WebKit process on the
  Mac (Safari, Mail, other apps) drops caches, not only Tilr's. WebKit has no per-view or
  per-process memory-pressure call (checked on macOS 26: nothing on `WKWebView`, `WKProcessPool`,
  `WKWebsiteDataStore`). Test: `python3 scripts/test_footprint.py`.
- To see and drive the running app, use Tilr Control (`Sources/Tilr/Control.swift`): `tilr ctl
  snapshot PATH`, `tilr ctl console`, `tilr ctl call SERVICE.METHOD …` (the CLI of the web repo),
  or the `tilr` MCP server. After a Swift change, check it in the test instance (`./run.sh --test`).
  `tilr ctl switch` accepts `"slide": true`. The console is caught only with
  `control.console_capture` (at launch), batched per microtask and cut at
  `control.console_entry_max` characters; `debug.inspectable` (at launch) controls Safari → Develop.
  `SiteSchemeHandler` serves the apps' files on a background queue.
  The relay serializes an object argument only up to the cut (a `JSON.stringify` replacer that
  rebuilds the text and stops the walk), so a huge object costs about `console_entry_max`
  characters; the kept text equals a full `JSON.stringify` cut (`--probe` compares them).
- **Refresh rate**: `web.high_refresh_rate` (at launch) lifts WebKit's 60 Hz rendering cap on
  120 Hz panels (no effect on a 75 Hz display). `--probe` asserts the switch only; check the rate
  by hand in the test instance with the window on the built-in display:
  `tilr ctl debug status` (`highRefreshRate: true`) and
  `tilr ctl eval 'const ts=[]; await new Promise(r => { const f = t => { ts.push(t); t - ts[0] < 2000 ? requestAnimationFrame(f) : r() }; requestAnimationFrame(f) }); return (ts.length - 1) / ((ts.at(-1) - ts[0]) / 1000)'`
  (≈120 with the key, ≈60 without; the window must be visible, `document.visibilityState`).
