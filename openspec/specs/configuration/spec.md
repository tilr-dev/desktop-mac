# configuration Specification

## Purpose
Define generated defaults, user overrides, configuration reload and isolation between application instances.

## Requirements

### Requirement: Config directory selection and generated defaults
Tilr SHALL select its configuration directory from `--config DIR`, then `TILR_CONFIG`, then `~/Library/Application Support/dev.tilr.mac`, and maintain defaults separately from user overrides.

#### Scenario: First launch and relative paths
- **WHEN** Tilr starts with a selected config directory
- **THEN** it creates the directory and missing `config.yml`, writes the current settings to `default.yml`, expands `~` in paths, and resolves relative configuration paths against this directory
- **AND** subsequent launches replace generated defaults when needed without replacing an existing user config

### Requirement: Settings merging and reload
Tilr SHALL merge YAML maps key by key, replace lists and scalar values as a whole, and retain the last valid configuration after an invalid edit.

#### Scenario: Save overrides
- **WHEN** `config.yml` is saved
- **THEN** Tilr loads overrides over defaults and reapplies reloadable settings; missing or comment-only config supplies no overrides
- **AND** a parse/decode failure is printed with the config path and leaves the last good configuration active (defaults if startup parsing fails)

#### Scenario: Settings with launch-only lifetime
- **WHEN** a valid config is reloaded
- **THEN** window mode and activation, preload policy, control socket and console capture/entry limit, native plugin directory/enabled/trust/timeout, web refresh mode and inspectability retain their launch-time values
- **AND** window geometry settings, menus/shortcuts, app list/sites, plugin-manager workspace/catalog, native plugin options, browser reloadable settings and local-server enabled state are reapplied according to their individual lifetimes

### Requirement: Separate application instances
Tilr SHALL isolate a non-default config directory's web storage, profile storage, process identity and window title from the default instance.

#### Scenario: Run a test instance beside production
- **WHEN** Tilr runs with a non-default config directory
- **THEN** it persists a UUID in `storage-id`, uses that instance's website data store, derives each browser profile store from the instance UUID and profile UUID, and appends ` · <folder name>` to its window title
- **AND** the default instance retains its default website data store
- **AND** each instance writes `<config>/tilr.pid` and removes it on quit only if it still contains its own PID
