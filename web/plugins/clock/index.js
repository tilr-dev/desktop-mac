// A tile with the time. Save this file and only this tile is replaced: the page, the other
// plugins and the panel stay as they are. Try SHOW_SECONDS or the zone.
const SHOW_SECONDS = true
const ZONE = undefined // e.g. 'America/New_York'

export default {
  name: 'clock',
  inject: ['ui'],
  apply(ctx) {
    const body = ctx.ui.tile({ title: 'clock' })
    const time = document.createElement('div')
    time.className = 'big'
    const note = document.createElement('div')
    note.className = 'muted'
    note.textContent = ZONE ?? 'local time'
    body.append(time, note)

    const format = new Intl.DateTimeFormat('en-GB', {
      hour: '2-digit', minute: '2-digit', second: SHOW_SECONDS ? '2-digit' : undefined,
      hourCycle: 'h23', timeZone: ZONE,
    })
    const tick = () => { time.textContent = format.format(new Date()) }
    tick()
    // The interval is an effect: it is cleared when the plugin is disabled or reloaded.
    ctx.effect(() => {
      const id = setInterval(tick, 1000)
      return () => clearInterval(id)
    }, 'clock interval')
  },
}
