// Depends on the counter service. cordis only runs this plugin while 'counter' exists:
// disable or reload the counter plugin and this tile disappears, then comes back.
export default {
  name: 'stats',
  inject: ['ui', 'counter'],
  apply(ctx) {
    const body = ctx.ui.tile({ title: 'stats' })
    const line = document.createElement('div')
    const since = document.createElement('div')
    since.className = 'muted'
    since.textContent = `mounted ${new Date().toLocaleTimeString('en-GB')}`
    body.append(line, since)

    let clicks = 0
    const render = () => {
      line.innerHTML = `counter is <span class="green"></span>, <b></b> clicks since mount`
      line.querySelector('span').textContent = ctx.counter.value
      line.querySelector('b').textContent = clicks
    }
    // The listener is removed with the plugin.
    ctx.on('counter/change', () => {
      clicks++
      render()
    })
    render()
  },
}
