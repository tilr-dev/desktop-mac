// The on/off panel: one row per plugin in plugins.json with its state, a reload-from-disk
// button and a switch. It is a plugin like the others; `locked` keeps its own switch off.
export default {
  name: 'panel',
  locked: true,
  inject: ['ui', 'plugins'],
  apply(ctx) {
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
