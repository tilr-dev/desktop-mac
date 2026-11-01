# app-shell Specification

## Purpose
Define the native window, app switching, command palette and verified desktop placement behavior.

## Requirements

### Requirement: Command palette and native menus
Tilr SHALL expose configurable commands through a palette and native menu shortcuts while preserving normal text input to the page.

#### Scenario: Find and run a command
- **WHEN** cmd+shift+p opens the default palette
- **THEN** typing filters commands, up/down changes selection, Return runs the selected command, and Escape or clicking elsewhere closes it
- **AND** commands support quit, new-window, fullscreen, window, frameless, always-on-top, reload, all-desktops, next-desktop and debug; optional `key` runs a command directly
- **AND** commands target the key window and toggle states are reflected in menu/palette rows; debug opens the shared Performance window
- **AND** native Edit actions allow cmd+c/cmd+v in WebKit; shortcuts use menus so unbound keys reach the terminal

### Requirement: Desktop placement
Tilr SHALL offer per-window all-desktops and next-desktop commands with guarded private WindowServer operations and confirmation of desktop moves.

#### Scenario: Desktop move cannot be confirmed
- **WHEN** a desktop move is requested for the key window
- **THEN** Tilr uses desktop Spaces in Mission Control order, checks membership until `window.space_move_timeout` (default 3 seconds) at `space_move_interval` (default 0.05 seconds), and reports unsuccessful movement rather than assuming symbol availability proves success
- **AND** unsupported private APIs leave their dependent feature unavailable

### Requirement: First click in an inactive window
A press in an inactive Tilr window SHALL activate the window and reach the page under it as an ordinary mousedown, without a separate activating click.

#### Scenario: Drag a layout window's header from an inactive window
- **WHEN** the user presses on a draggable header of the page in a Tilr window that is not key
- **THEN** the window becomes key and the page receives that press, so the drag starts with it

#### Scenario: Controls and browser views take the first click
- **WHEN** the user clicks a page control, or a browser plugin web view, in a Tilr window that is not key
- **THEN** the click acts at once, as it would in the key window
- **AND** this holds for the page view made after an app change replaces the previous one

### Requirement: Native application windows
Tilr SHALL maintain a persistent set of native windows, each with a stable host UUID and one full runtime page for one configured application, allowing multiple windows of the same application with shared instance website storage.

#### Scenario: Create and switch application windows
- **WHEN** the user selects an application through Apps, ctrl+alt+1..9, ctrl+alt+left/right, or Control switch
- **THEN** Tilr focuses an existing window for that application, preferring the key window, or creates one if none exists
- **AND** Apps checks the key window's application; menus, palette and changed notifications follow that window
- **AND** New Window in the menu or palette opens another independent page of the key window's application
- **AND** opened and restored pages are visible, fill their host content and follow its size
- **AND** each host UUID is visible in its window UI and lifecycle log

#### Scenario: Restore independent presentation
- **WHEN** Tilr restarts after two windows of the same application have been moved or changed independently
- **THEN** both hosts and their application, desktop frames, screens, modes, Space placement and always-on-top state are restored
- **AND** window and frameless modes preserve desktop size and position; fullscreen covers the selected screen with Dock/menu bar hidden
- **AND** native fullscreen entered with the green button records fullscreen mode without overwriting desktop geometry
- **AND** rearranged connected displays restore onto the recorded screen identity
- **AND** unavailable screens use a reachable fallback and unavailable private Space APIs leave placement unsupported
- **AND** first launch without usable saved state creates one window for the default application using window configuration defaults

#### Scenario: Close one host
- **WHEN** a native window closes
- **THEN** only its page, SSH agent streams and native resources stop and other windows remain open
- **AND** closing the final window uses the existing termination behavior and retains the final workspace for restart

#### Scenario: Frameless input
- **WHEN** a window uses frameless presentation
- **THEN** dragging starts in the top drag_height points (default 32), excluding resize_border (default 6)
- **AND** a header click reaches page controls and the window accepts keyboard focus
