// The on/off panel: one row per plugin in plugins.json with its state, a reload-from-disk
// button and a switch. It is a plugin like the others; `locked` keeps its own switch off.
// It does not depend on the theme (so it stays usable when no theme is on): its own styles
// use the theme's tokens with fallbacks.
const css = `
  .plugins { list-style: none; margin: 0; padding: 0; }
  .plugins li { display: grid; grid-template-columns: 10px 1fr auto auto auto; gap: 10px; align-items: center; padding: 4px 0; }
  .plugins .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--line, #1e1e2e); }
  .plugins .dot.active { background: var(--accent, #6dd08c); }
  .plugins .dot.failed { background: var(--danger, #ff5d5d); }
  .plugins .dot.pending, .plugins .dot.loading { background: var(--muted, #9399b2); }
  .plugins .name small { color: var(--muted, #9399b2); font-size: 10px; margin-left: 6px; }
  .plugins .state { color: var(--muted, #9399b2); font-size: 11px; }
  .plugins .error { grid-column: 1 / -1; color: var(--danger, #ff5d5d); font-size: 11px; white-space: pre-wrap; }
`

export default {
  name: 'panel',
  locked: true,
  inject: ['ui', 'plugins'],
  apply(ctx) {
    ctx.ui.style(css)
    const body = ctx.ui.tile({ title: 'plugins' })
    const list = document.createElement('ul')
    list.className = 'plugins'
    body.append(list)

    function render() {
      list.replaceChildren(...ctx.plugins.list().map(plugin => {
        const row = document.createElement('li')
        row.innerHTML = `
          <span class="dot"></span><span class="name"></span><span class="state"></span>
          <button title="reload from disk">↻</button>
          <input class="switch" type="checkbox" title="on / off">`
        const [dot, name, state, reload, toggle] = row.children
        dot.classList.add(plugin.state)
        name.textContent = plugin.name
        if (plugin.provides) {
          // e.g. "theme": switching this on switches the other provider off.
          const tag = document.createElement('small')
          tag.textContent = plugin.provides
          name.append(tag)
        }
        state.textContent = plugin.loadedAt && plugin.state === 'active'
          ? new Date(plugin.loadedAt).toLocaleTimeString('en-GB') : plugin.state
        reload.onclick = () => ctx.plugins.reload(plugin.name).then(console.log)
        toggle.checked = plugin.enabled
        toggle.disabled = plugin.locked
        toggle.onchange = () => ctx.plugins.toggle(plugin.name)
        if (plugin.error) {
          const error = document.createElement('div')
          error.className = 'error'
          error.textContent = plugin.error.message
          row.append(error)
        }
        return row
      }))
    }

    // State changes arrive mid-transition; render once the current work settles.
    let queued = false
    ctx.on('plugins/change', () => {
      if (queued) return
      queued = true
      queueMicrotask(() => { queued = false; render() })
    })
    render()
  },
}
