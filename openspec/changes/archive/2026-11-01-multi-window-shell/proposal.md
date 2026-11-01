# Multiple native application windows

## Why
A single window with app tabs cannot present two pages of the same application independently. Native windows need stable identities and a durable workspace.

## What Changes
- Replace tabs, sliding and preload with one app page per native window.
- Persist the open window set, identities, presentation and placement.
- Route app switching, menus and Control through the key window.

## Impact
App shell, configuration defaults, page/plugin lifecycle, Control and regression probes.
