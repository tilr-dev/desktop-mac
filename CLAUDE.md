# Tilr for Mac

WKWebView shell: one window per app from the config, each a folder served as `tilr://<name>/`.
Swift Package, AppKit, no Xcode project. `./run.sh` builds and starts the app; `./run.sh --probe`
runs the self-check (page, palette, app switching, Space move) and quits — run it after changes.

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
