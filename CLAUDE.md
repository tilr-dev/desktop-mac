# Tilr for Mac

WKWebView shell: one window, a tab per app from the config (no tab bar, switched by shortcut),
each a folder served as `tilr://<name>/`.
The page's web views (the `webviews` service of the web repo, a plugin's browser window) are
WKWebViews of ours placed over the page (`Sources/Tilr/WebViews.swift`), in an overlay of their
own, ordered and masked (holes) as the page stacks their hosts: a float over a browser tile shows.
Swift Package, AppKit, no Xcode project. `./run.sh` builds and starts the app; `./run.sh --probe`
runs the self-check (page, palette, app switching, Space move) and quits — run it after changes.

Desktop modes share the last window frame: switching window / frameless / fullscreen restores
the user's desktop size and position. `window.inset` chooses the initial frame only.
In frameless mode the top `window.drag_height` points move the window using AppKit's drag;
the `window.resize_border` perimeter is reserved for resizing. A click still reaches the
header's clock. `--probe` asserts frame restoration and the header / resize hit boundaries.

## Rules

- Every tunable goes into the config, never as a literal in code: durations, sizes, margins,
  shortcuts, modes, names. Add it to `Config.defaultText` in `Sources/Tilr/Config.swift` with a
  comment saying what it does and its unit, add the field to the `Config` struct, read it from
  `config`. The app writes that text to `~/.config/tilr/default.yml` on every launch; the user
  overrides keys in `config.yml` next to it (Sublime model: defaults + overrides, maps merged key
  by key, lists and values replaced whole). Never put defaults into `config.yml` or into the code.
- A setting applies on config reload (the file is watched) unless its comment in the defaults
  says "at launch".
- Keep `./run.sh --probe` passing; extend it when a feature can be checked from code.
- To see and drive the running app, use Tilr Control (`Sources/Tilr/Control.swift`): `tilr ctl
  snapshot PATH`, `tilr ctl console`, `tilr ctl call SERVICE.METHOD …` (the CLI of the web repo),
  or the `tilr` MCP server. Restart the app after a Swift change (`./run.sh`).
