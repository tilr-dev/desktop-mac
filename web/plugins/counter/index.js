// A class plugin that is also a service: other plugins get it as ctx.counter (see stats).
// Switch it off and every plugin that injects 'counter' is unloaded by cordis; switch it on
// and they come back. Reloading this file does the same round trip.
import { Service } from 'cordis'

const STEP = 1

export default class Counter extends Service {
  static inject = ['ui']

  constructor(ctx) {
    super(ctx, 'counter')
    // Callers reach this service through a proxy, so `this` in a method may be a derived
    // object: keep mutable state in one holder object, not in own fields.
    this.state = { value: 0 }

    const body = ctx.ui.tile({ title: 'counter' })
    const value = document.createElement('div')
    value.className = 'big'
    const button = document.createElement('button')
    button.textContent = `+${STEP}`
    button.onclick = () => this.add(STEP)
    body.append(value, button)
    this.render = () => { value.textContent = String(this.state.value) }
    this.render()
  }

  get value() {
    return this.state.value
  }

  add(n = STEP) {
    this.state.value += n
    this.render()
    this.ctx.emit('counter/change', this.state.value)
  }
}
