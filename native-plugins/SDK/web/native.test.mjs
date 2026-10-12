import { test } from 'node:test'
import assert from 'node:assert/strict'
import { connectNative } from './native.mjs'

function emit(target, name, detail) {
  const event = new Event(name)
  event.detail = detail
  target.dispatchEvent(event)
}

test('correlates out-of-order replies and native errors', async () => {
  const page = new EventTarget(), sent = []
  page.webkit = { messageHandlers: { tilrNative: { postMessage: body => sent.push(body) } } }
  const client = connectNative({ window: page })
  const first = client.describe()
  const second = client.send('audio', 'audio', { op: 'list' })
  emit(page, 'tilr-native', { id: sent[1].id, result: { accepted: true } })
  emit(page, 'tilr-native', { id: sent[0].id, result: ['audio'] })
  assert.deepEqual(await first, ['audio'])
  assert.deepEqual(await second, { accepted: true })
  const bad = client.send('missing', 'audio', {})
  emit(page, 'tilr-native', { id: sent[2].id, error: 'unavailable' })
  await assert.rejects(bad, /unavailable/)
  client.dispose()
})

test('dispose rejects pending calls and removes provider listeners', async () => {
  const page = new EventTarget()
  page.webkit = { messageHandlers: { tilrNative: { postMessage() {} } } }
  const client = connectNative({ window: page })
  let events = 0
  client.on('tilr-audio', () => events++)
  const pending = client.describe()
  client.dispose()
  emit(page, 'tilr-audio', {})
  assert.equal(events, 0)
  await assert.rejects(pending, /disposed/)
  await assert.rejects(client.describe(), /disposed/)
})
