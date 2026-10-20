# app-shell Specification

## Purpose
TBD - created by archiving change bootstrap-desktop-mac. Update Purpose after archive.

## Requirements

### Requirement: One window with configurable presentation
Tilr SHALL host its apps as tabs of one native window supporting `window`, `frameless` and `fullscreen` modes.

#### Scenario: Window modes and geometry
- **WHEN** the user changes mode through Commands or the palette
- **THEN** `window` has a title bar, `frameless` has none, and fullscreen covers the current screen with Dock/menu bar hidden
- **AND** mode changes preserve the last desktop size and position; initial desktop geometry uses `window.inset` (default x=200, y=150)
- **AND** a frameless drag starts in the top `drag_height` points (default 32), excluding the `resize_border` perimeter (default 6) reserved for resizing
- **AND** a click in the draggable header still reaches page controls such as the clock; the frameless window accepts keyboard focus

### Requirement: Tab selection and preload
Tilr SHALL show one app tab at a time, with configurable directional sliding and deferred loading of background tabs.

#### Scenario: Default switching controls
- **WHEN** the user presses ctrl+alt+right/left or ctrl+alt+1..9
- **THEN** Tilr cycles or selects the corresponding app in config order; the Apps menu lists apps and checks the selected entry
- **AND** switching uses `switch.duration` (default 0.3 seconds) and `switch.easing` (default ease-in-out; also ease-in, ease-out, linear); duration zero switches immediately
- **AND** hidden tab containers keep their size during window resizing; the slide moves compositor layers rather than repeatedly resizing WebKit views

#### Scenario: Preload policy
- **WHEN** `switch.preload` is false, true, or a number N (default 2 seconds)
- **THEN** background tabs respectively load on first selection, at launch, or N seconds after the first visible page finishes or fails
- **AND** selecting an unloaded tab loads it immediately; an unloaded tab has no watcher or started native providers
- **AND** apps added later load on selection, except with true they load immediately

### Requirement: Command palette and native menus
Tilr SHALL expose configurable commands through a palette and native menu shortcuts while preserving normal text input to the page.

#### Scenario: Find and run a command
- **WHEN** cmd+shift+p opens the default palette
- **THEN** typing filters commands, up/down changes selection, Return runs the selected command, and Escape or clicking elsewhere closes it
- **AND** commands support quit, fullscreen, window, frameless, always-on-top, reload, all-desktops, next-desktop and debug; optional `key` runs a command directly
- **AND** toggle states are reflected in menu/palette rows; debug opens the shared Performance window
- **AND** native Edit actions allow cmd+c/cmd+v in WebKit; shortcuts use menus so unbound keys reach the terminal

### Requirement: Desktop placement
Tilr SHALL offer all-desktops and next-desktop commands with guarded private WindowServer operations and confirmation of desktop moves.

#### Scenario: Desktop move cannot be confirmed
- **WHEN** a desktop move is requested
- **THEN** Tilr uses desktop Spaces in Mission Control order, checks membership until `window.space_move_timeout` (default 3 seconds) at `space_move_interval` (default 0.05 seconds), and reports unsuccessful movement rather than assuming symbol availability proves success
- **AND** unsupported private APIs leave their dependent feature unavailable
