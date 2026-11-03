## ADDED Requirements

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
