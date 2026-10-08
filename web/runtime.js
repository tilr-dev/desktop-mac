// The plugin runtime: one cordis root context, two services every plugin can inject, and the
// hot-reload entry the native app calls when files under plugins/ change.
//
// A plugin is plugins/<name>/index.js, listed in plugins.json. Its default export is a cordis
// plugin: an object { name, inject, apply(ctx) }, or a class (see plugins/counter). Everything a
// plugin does goes through ctx (ctx.effect, ctx.on, ctx.provide, ctx.ui.tile), so disposing its
// fiber undoes all of it — that is what makes swapping a plugin in place safe.
//
// Hot reload = import the new module (with a cache-busting query, the module map is keyed by
// URL), dispose the old fiber, start a new one. Plugins that inject a service the reloaded
// plugin provides are unloaded and reloaded by cordis itself.
//
// Limit: a plugin is one file. A module it imports relatively would stay cached across reloads.
// (Files it fetches, like a theme's CSS, are read fresh every start.)
import { Context, Service } from 'cordis'
import { adopt } from 'tilr'

const STORAGE_KEY = 'tilr-plugins-off'
const STATE = ['pending', 'loading', 'active', 'failed', 'disposed', 'unloading']

const root = new Context()
root.logger.exporter({
  export(message) {
    const log = console[message.type] ?? console.log
    log(`[${message.name}]`, ...message.args)
  },
})

/** `ctx.ui.tile({ title })` → the tile's body element; `ctx.ui.style(css)` → a stylesheet.
 *  Both leave with the plugin. Colors come from the theme's tokens (var(--accent) …). */
class UI extends Service {
  constructor(ctx) {
    super(ctx, 'ui')
  }

  style(css) {
    const sheet = new CSSStyleSheet()
    sheet.replaceSync(css)
    this.ctx.effect(() => adopt(document, sheet), 'ui.style()')
  }

  tile({ title } = {}) {
    // this.ctx is the caller's context: the effect belongs to the plugin, not to the ui service.
    const ctx = this.ctx
    const tile = document.createElement('section')
    tile.className = 'tile'
    tile.innerHTML = '<header></header><div class="body"></div>'
    tile.querySelector('header').textContent = title ?? ctx.fiber.name
    ctx.effect(() => {
      document.getElementById('grid').append(tile)
      return () => tile.remove()
    }, 'ui.tile()')
    return tile.querySelector('.body')
  }
}

/** `ctx.plugins`: the plugin list, their fibers, on/off switches and reload from disk. */
class PluginHost extends Service {
  constructor(ctx) {
    super(ctx, 'plugins')
    // Methods are called through the service proxy with the caller's ctx; plugins must be
    // started from this one so they are owned by the host.
    this.scope = ctx
    this.entries = new Map()
    this.off = new Set(read())
    ctx.on('internal/status', () => this.changed())
  }

  changed() {
    this.scope.emit('plugins/change')
  }

  /** Rows for the panel. */
  list() {
    return [...this.entries.values()].map(entry => ({
      name: entry.name,
      enabled: !this.off.has(entry.name),
      locked: !!entry.module?.default?.locked,
      provides: entry.module?.default?.provide ?? null,
      state: entry.error ? 'failed' : entry.fiber ? STATE[entry.fiber.state] : 'off',
      error: entry.error,
      loadedAt: entry.loadedAt,
    }))
  }

  /** Reads plugins.json and adds, removes and (re)starts plugins to match it. */
  async sync() {
    const response = await fetch(new URL('./plugins.json', import.meta.url), { cache: 'no-store' })
    const names = (await response.json()).plugins
    const notes = []
    for (const name of [...this.entries.keys()]) {
      if (names.includes(name)) continue
      await this.stop(this.entries.get(name))
      this.entries.delete(name)
      notes.push(`${name}: removed`)
    }
    for (const name of names) {
      if (this.entries.has(name)) continue
      this.entries.set(name, { name, module: null, fiber: null, error: null, loadedAt: null })
      notes.push(await this.reload(name))
    }
    this.changed()
    return notes.join(', ') || 'plugins.json: no change'
  }

  /** Imports the plugin's file again and swaps the running instance for the new code. */
  async reload(name) {
    const entry = this.entries.get(name)
    if (!entry) return `${name}: not in plugins.json`
    let module
    try {
      module = await import(new URL(`./plugins/${name}/index.js?v=${Date.now()}`, import.meta.url))
      if (!module.default) throw new Error('no default export')
    } catch (error) {
      // The old instance keeps running; the panel shows why the new one did not start.
      entry.error = error
      this.changed()
      return `${name}: import failed: ${error.message}`
    }
    await this.stop(entry)
    entry.module = module
    entry.loadedAt = Date.now()
    this.start(entry)
    return `${name}: reloaded`
  }

  /** Another running plugin that provides the same service (two themes at once). */
  rival(entry) {
    const provide = entry.module?.default?.provide
    if (!provide) return
    for (const other of this.entries.values()) {
      if (other !== entry && other.fiber && other.module?.default?.provide === provide) return other
    }
  }

  start(entry) {
    if (this.off.has(entry.name) || entry.fiber) return
    // One provider per service: a second one is switched off instead of failing on provide().
    if (this.rival(entry)) {
      this.off.add(entry.name)
      write([...this.off])
      this.changed()
      return
    }
    entry.error = null
    entry.fiber = this.scope.plugin(entry.module.default)
    entry.fiber.await().catch(error => {
      entry.error = error
      this.changed()
    })
    this.changed()
  }

  async stop(entry) {
    const fiber = entry.fiber
    entry.fiber = null
    entry.error = null
    if (fiber) await fiber.dispose()
    this.changed()
  }

  async toggle(name) {
    const entry = this.entries.get(name)
    if (!entry || entry.module?.default?.locked) return
    if (this.off.delete(name)) {
      // Switching a theme on switches the running one off: the service name is taken.
      const rival = this.rival(entry)
      if (rival) {
        this.off.add(rival.name)
        await this.stop(rival)
      }
      this.start(entry)
    } else {
      this.off.add(name)
      await this.stop(entry)
    }
    write([...this.off])
  }
}

function read() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) ?? [] } catch { return [] }
}

function write(names) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(names)) } catch {}
}

await root.plugin(UI)
await root.plugin(PluginHost)
const host = root.get('plugins')

// Called by the native app (main.swift) with paths relative to the site folder. The return
// value lands in the app's stdout. Anything else than plugins/… reloads the whole page there.
window.tilr = {
  root,
  hmr: {
    async changed(paths) {
      const names = new Set()
      let manifest = false
      for (const path of paths) {
        if (path === 'plugins.json') manifest = true
        const match = /^plugins\/([^/]+)\//.exec(path)
        if (match) names.add(match[1])
      }
      const notes = []
      const started = Date.now()
      if (manifest) notes.push(await host.sync())
      for (const name of names) {
        // A plugin that sync() just added was imported from disk a moment ago.
        if (host.entries.get(name)?.loadedAt >= started) continue
        notes.push(await host.reload(name))
      }
      return notes.join('; ')
    },
  },
}

console.log(await host.sync())
