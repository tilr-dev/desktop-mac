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
- **THEN** activation policy, control socket and console capture/entry limit, native plugin directory/enabled/trust/timeout, web refresh mode and inspectability retain their launch-time values
- **AND** window settings become defaults for new windows without resetting existing hosts; menus/shortcuts, app list/sites, plugin-manager workspace/catalog, native plugin options, browser reloadable settings and local-server enabled state are reapplied according to their individual lifetimes

### Requirement: Separate application instances
Tilr SHALL isolate a non-default config directory's web storage, profile storage, process identity and window title from the default instance.

#### Scenario: Run a test instance beside production
- **WHEN** Tilr runs with a non-default config directory
- **THEN** it persists a UUID in `storage-id`, uses that instance's website data store, derives each browser profile store from the instance UUID and profile UUID, and appends ` · <folder name>` to its window title
- **AND** the default instance retains its default website data store
- **AND** each instance writes `<config>/tilr.pid` and removes it on quit only if it still contains its own PID

### Requirement: Page access to config files
Tilr SHALL expose a tilrConfig message handler for UTF-8 files directly in Config.dir, accepting only its owning trusted top-level application page.

#### Scenario: Read and write a plugin file
- **WHEN** the trusted page writes test.yml with text a: 1 and then reads it
- **THEN** the file in Config.dir contains that text, write replies with ok true, and read returns that text
- **AND** a missing file reads as null; config.yml and default.yml can be read

#### Scenario: Reject unsafe access
- **WHEN** a request uses an empty name, dot name, double dots, slash, backslash, NUL, directory or symbolic link, writes config.yml or default.yml (including case variants), or comes from a foreign origin or subframe
- **THEN** it receives a descriptive error without reading or writing the target

### Requirement: Config file change delivery
Tilr SHALL send a tilr:config CustomEvent with detail { name } for changes to direct files in Config.dir to every trusted application page, retaining configuration reload behavior.

#### Scenario: External edit
- **WHEN** an editor saves test.yml in Config.dir using the default watch settings
- **THEN** each trusted page receives tilr:config with name test.yml within one second
- **AND** duplicate paths in one watcher batch produce one event per filename, nested paths are excluded, and config.yml still reloads application settings

#### Scenario: Navigation before event delivery
- **WHEN** a page navigates away from its trusted app origin before event JavaScript runs
- **THEN** config file events are not dispatched to the new origin
