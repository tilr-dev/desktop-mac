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
- `ctx.plugins` → the host: `list()`, `toggle(name)`, `reload(name)`, `sync()`.
  It emits `plugins/change` on every state change.

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
