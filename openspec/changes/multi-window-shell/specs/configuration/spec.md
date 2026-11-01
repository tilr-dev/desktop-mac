
## MODIFIED Requirements

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
