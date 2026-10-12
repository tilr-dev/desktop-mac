/** SDK bridge for new paired web/native plugins. Existing tilrAudio/tilrWebViews
 * aliases remain compatible. send() acknowledges dispatch; provider events carry
 * state/results. Native control/automation services are never exposed here. */
export function connectNative({ window: page = globalThis.window, timeout = 10000 } = {}) {
  if (!Number.isFinite(timeout) || timeout <= 0) throw new Error('timeout must be positive')
  const handler = page?.webkit?.messageHandlers?.tilrNative
  if (!handler) throw new Error('Tilr native plugins are unavailable')
  const pending = new Map()
  const subscriptions = new Set()
  // Correlation only, not authentication. Works on custom-scheme origins where
  // crypto.randomUUID may be unavailable (it requires a secure context).
  const prefix = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
  let sequence = 0
  let disposed = false
  const reply = ({ detail }) => {
    const finish = pending.get(detail?.id)
    if (finish) finish(detail.error ? new Error(detail.error) : null, detail.result)
  }
  page.addEventListener('tilr-native', reply)
  function request(body) {
    if (disposed) return Promise.reject(new Error('native bridge disposed'))
    const id = `${prefix}:${++sequence}`
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => finish(new Error('native bridge timed out')), timeout)
      function finish(error, value) {
        if (!pending.delete(id)) return
        clearTimeout(timer)
        if (error) reject(error); else resolve(value)
      }
      pending.set(id, finish)
      try { handler.postMessage({ ...body, id }) } catch (error) { finish(error) }
    })
  }
  return {
    describe: () => request({ op: 'describe' }),
    send: (plugin, channel, message) => request({ op: 'send', plugin, channel, message }),
    on(event, listener) {
      if (disposed) throw new Error('native bridge disposed')
      const receive = ({ detail }) => listener(detail)
      page.addEventListener(event, receive)
      const off = () => { page.removeEventListener(event, receive); subscriptions.delete(off) }
      subscriptions.add(off)
      return off
    },
    dispose() {
      disposed = true
      page.removeEventListener('tilr-native', reply)
      for (const off of subscriptions) off()
      for (const finish of pending.values()) finish(new Error('native bridge disposed'))
    },
  }
}
