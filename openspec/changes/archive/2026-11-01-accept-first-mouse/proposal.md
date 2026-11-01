# Take the first click in an inactive window

## Why
A click into an inactive Tilr window only activated the window: WebKit's own first-mouse answer is yes only over a selection or a scroller, so the press never reached the page. Dragging a layout window's header from another Tilr window needed a second press; the demo runtime avoids this by accepting the first mouse.

## What Changes
- The app's page view and the browser plugin's web views accept the first mouse: the first press in an inactive window activates it and reaches the page as an ordinary mousedown (header drags start, buttons act).
- `--probe` checks that the page view (also after it is replaced) and a browser view accept the first mouse.

## Impact
- app-shell specification (new requirement).
- `Sources/Tilr/Tab.swift`, `native-plugins/Sources/BrowserWebKit/WebViews.swift`, the probes.
