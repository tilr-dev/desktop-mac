# Tilr web: plugins with hot reload

The page is a cordis root context plus plugins. Everything on screen, the header included, is
a plugin in `plugins/<name>/index.js`, listed in `plugins.json`. The native app watches the site
folder (`~/tilr-mac`): a change under `plugins/` or to `plugins.json` is handed to the page and
only the affected plugins are swapped; a change to any other file reloads the page.

## Writing a plugin

```js
// plugins/hello/index.js
export default {
  name: 'hello',
  inject: ['ui'],            // services this plugin needs; it waits for them
  apply(ctx) {
    const body = ctx.ui.tile({ title: 'hello' })   // a tile that leaves with the plugin
    body.textContent = 'hi'
    ctx.effect(() => {       // anything else that must be undone on unload
      const id = setInterval(() => {}, 1000)
      return () => clearInterval(id)
    })
  },
}
```

Rules that make hot reload safe:

- Touch the outside world only through `ctx`: `ctx.effect`, `ctx.on`, `ctx.provide`, `ctx.ui.tile`.
  Disposing the plugin's fiber undoes all of it in reverse order.
- A plugin is one file. A module imported relatively from it stays cached across reloads.
- A class plugin that extends `Service` becomes a service under its name (`plugins/counter`).
  Keep mutable state in one holder object (`this.state = {...}`): callers reach the service
  through a proxy, and `this` in a method may be a derived object.
- `locked: true` on the export hides the on/off switch (the panel uses it).

## Services

- `ctx.ui.tile({ title })` → the tile's body element, removed when the plugin unloads.
- `ctx.ui.style(css)` → a stylesheet that lives as long as the plugin. Use the theme's tokens
  (`var(--accent)`), never literal colors.
- `ctx.plugins` → the host: `list()`, `toggle(name)`, `reload(name)`, `sync()`.
  It emits `plugins/change` on every state change.
- `ctx.theme` → the running theme: `sheet` (its CSSStyleSheet), `attach(shadowRoot)` (gives a
  shadow root the theme's classes), `variant` (plugin name). Inject it only when you call it;
  the theme's styles apply to the document anyway.

## Themes: the style guide is a plugin

The look lives in one CSS file per theme, nothing else: `plugins/theme/theme.css` (dark,
default) and `plugins/theme-light/light.css`. A theme plugin is two lines:

```js
import { theme } from 'tilr'
export default theme(import.meta.url, './my.css')
```

The contract a theme fulfils is the token set and the base classes in `theme.css`:
tokens `--bg --panel --line --accent --on-accent --danger --text --muted --font --radius --gap`,
classes `.tile` (with `> header`, `> .body`), `.big .muted .accent .danger`, `button`, `.switch`,
and `#grid`. Plugins style themselves with these and define no colors of their own.

To restyle Tilr, do not edit an existing theme: add `plugins/<my-theme>/` with your CSS and
switch to it in the panel. Themes `provide: 'theme'`, and the host runs one provider per
service: switching a theme on switches the running one off (the first listed in
`plugins.json` wins at startup). Saving a theme's CSS hot-reloads it like any plugin: the
theme is restarted, and plugins that inject it (the header) are remounted by cordis.

## Adding, removing, editing at runtime

- Add: create `plugins/<name>/index.js`, add the name to `plugins.json`. Either order works.
- Remove: delete the name from `plugins.json`. The plugin is disposed and its tile removed.
- Edit: save the file. The new module is imported with a cache-busting query, the old fiber is
  disposed, the new one started. A syntax error keeps the old instance running and shows the
  error in the panel.
- Plugins that inject a service another plugin provides are unloaded and reloaded by cordis
  when that plugin goes away or comes back (`stats` follows `counter`).
- Off switches persist in `localStorage['tilr-plugins-off']`.

From the Safari console (Develop → Tilr), a plugin can also be started without a file:
`window.tilr.root.plugin({ name: 'tmp', apply(ctx) { ... } })`. It is not in the panel and
does not survive a page reload.

## Files

- `runtime.js` — root context, `ui` and `plugins` services, `window.tilr.hmr.changed(paths)`
  (called by the app with site-relative paths; the return value lands in the app's stdout).
- `vendor/` — browser builds of cordis and cosmokit, mapped by the import map in `index.html`.
