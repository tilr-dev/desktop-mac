// The bar across the top of the window: the "~/ tilr ❯" wordmark on the left and a clock with a
// timezone dropdown on the right. A port of ~/nexus/configs/sketchybar — sizes and colors are
// sketchybarrc's. Everything lives in a shadow root; the page only gets pushed down by 32px.
// Every touch of the document is an effect, so switching the plugin off restores the page.

// tz: IANA name, empty = local time. tag: drawn before the digits in the bar (the local zone
// shows bare digits). name: drawn in the dropdown.
const ZONES = [
  { tz: '', tag: '', name: 'Zurich' },
  { tz: 'UTC', tag: 'UTC', name: 'UTC' },
  { tz: 'America/New_York', tag: 'NYC', name: 'New York' },
  { tz: 'Europe/Kyiv', tag: 'KYIV', name: 'Kyiv' },
  { tz: 'Europe/Moscow', tag: 'MSK', name: 'Moscow' },
]
const STORAGE_KEY = 'tilr-clock-zone'
const HEIGHT = 32

// Colors and the font are the theme's tokens; they inherit into the shadow root.
const css = `
  :host {
    position: fixed; inset: 0 0 auto 0; z-index: 2147483647;
    font: var(--font); line-height: 1; font-weight: bold;
    color: var(--text); cursor: default; user-select: none; -webkit-user-select: none;
  }
  /* 32pt is the notch strip. Items sit 1px below the middle, hence the top padding. */
  .bar {
    box-sizing: border-box; height: ${HEIGHT}px; padding: 2px 25px 0 17px;
    display: flex; align-items: stretch; justify-content: space-between;
    background: var(--bg); border-bottom: 1px solid var(--line);
  }
  .logo, .clock { display: flex; align-items: center; white-space: pre; }
  .tilde { margin-right: 3px; }
  .chevron { margin-left: 3px; }
  /* the "r": a glyph on an accent block that hangs 2px lower than the text */
  .block { position: relative; z-index: 0; padding: 0 3px 0 2px; color: var(--on-accent); }
  .block::before {
    content: ""; position: absolute; z-index: -1; left: 0; right: 0;
    top: calc(50% - 6.5px); height: 17px; border-radius: 2px; background: var(--accent);
  }
  /* digits over a thin accent rule */
  .clock { position: relative; padding: 0 4px; }
  .clock::after {
    content: ""; position: absolute; left: 0; right: 0;
    top: calc(50% + 9px); height: 2px; border-radius: 1px; background: var(--accent);
  }
  /* the dropdown hangs off the bar's bottom line, right edges aligned with the clock */
  .menu {
    position: absolute; top: ${HEIGHT - 1}px; right: 25px; padding: 0 5px;
    display: flex; flex-direction: column;
    background: var(--panel); border: 1px solid var(--line); border-radius: 0 0 var(--radius) var(--radius);
    color: var(--muted);
  }
  .menu[hidden] { display: none; }
  .row { width: 170px; height: 22px; margin: 2px 0; display: flex; align-items: center; white-space: pre; }
  .row:hover { background: var(--line); color: var(--accent); }
  .mark { font-size: 15px; margin: 0 12px 0 4px; }
`

export default {
  name: 'header',
  // Needs the theme: its classes (.accent) reach the shadow root through ctx.theme.attach().
  inject: ['theme'],
  apply(ctx) {
    const host = document.createElement('tilr-header')
    const root = host.attachShadow({ mode: 'open' })
    ctx.theme.attach(root)
    root.innerHTML = `
      <style>${css}</style>
      <div class="bar">
        <div class="logo"><span class="accent tilde">~/</span><span>til</span><span class="block">r</span><span class="accent chevron">❯</span></div>
        <div class="clock"></div>
      </div>
      <div class="menu" hidden></div>`
    const clock = root.querySelector('.clock')
    const menu = root.querySelector('.menu')

    const selected = () => {
      let index = 0
      try { index = Number.parseInt(localStorage.getItem(STORAGE_KEY), 10) } catch {}
      return index >= 0 && index < ZONES.length ? index : 0
    }
    const timeIn = zone => new Intl.DateTimeFormat('en-GB', {
      hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: zone.tz || undefined,
    }).format(new Date())

    function render() {
      const zone = ZONES[selected()]
      const text = zone.tag ? `${zone.tag} ${timeIn(zone)}` : timeIn(zone)
      if (clock.textContent !== text) clock.textContent = text
      if (!menu.hidden) renderRows()
    }

    // Rows are rebuilt only when their text changes, so a row under the pointer keeps its hover.
    function renderRows() {
      const current = selected()
      const rows = ZONES.map((zone, index) =>
        `${index === current ? '●' : '○'}|${zone.name.padEnd(9)} ${timeIn(zone)}`)
      if (menu.dataset.rows === rows.join('\n')) return
      menu.dataset.rows = rows.join('\n')
      menu.replaceChildren(...rows.map((row, index) => {
        const [mark, label] = row.split('|')
        const element = document.createElement('div')
        element.className = 'row'
        element.innerHTML = '<span class="mark"></span><span class="label"></span>'
        element.children[0].textContent = mark
        element.children[1].textContent = label
        element.onclick = () => {
          try { localStorage.setItem(STORAGE_KEY, String(index)) } catch {}
          close()
          render()
        }
        return element
      }))
    }

    function close() { menu.hidden = true }

    clock.onclick = () => {
      menu.hidden = !menu.hidden
      if (!menu.hidden) { delete menu.dataset.rows; renderRows() }
    }
    // Clicking the bar must not take keyboard focus away from the terminal under it.
    host.addEventListener('mousedown', event => event.preventDefault())

    // Make room: the page starts below the bar instead of under it.
    const push = document.createElement('style')
    push.textContent = `body{margin-top:${HEIGHT}px!important;height:calc(100dvh - ${HEIGHT}px)!important}`

    ctx.effect(() => {
      document.head.append(push)
      document.documentElement.append(host)
      return () => { host.remove(); push.remove() }
    }, 'header dom')

    // A click anywhere else, or leaving the window, dismisses the dropdown.
    ctx.effect(() => {
      const outside = event => { if (!event.composedPath().includes(host)) close() }
      document.addEventListener('pointerdown', outside, true)
      window.addEventListener('blur', close)
      return () => {
        document.removeEventListener('pointerdown', outside, true)
        window.removeEventListener('blur', close)
      }
    }, 'header listeners')

    render()
    ctx.effect(() => {
      const id = setInterval(render, 1000)
      return () => clearInterval(id)
    }, 'header clock')
  },
}
