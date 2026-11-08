## ADDED Requirements

### Requirement: First click in an inactive window
A press in an inactive Tilr window SHALL activate the window and reach the page under it as an ordinary mousedown, without a separate activating click.

#### Scenario: Drag a layout window's header from an inactive window
- **WHEN** the user presses on a draggable header of the page in a Tilr window that is not key
- **THEN** the window becomes key and the page receives that press, so the drag starts with it

#### Scenario: Controls and browser views take the first click
- **WHEN** the user clicks a page control, or a browser plugin web view, in a Tilr window that is not key
- **THEN** the click acts at once, as it would in the key window
- **AND** this holds for the page view made after an app change replaces the previous one
