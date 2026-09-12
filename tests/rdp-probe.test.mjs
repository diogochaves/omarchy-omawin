import assert from 'node:assert/strict'
import net from 'node:net'
import test from 'node:test'
import { rdpProbe } from './helpers.mjs'

// The 19-byte X.224 Connection Request the probe must send: TPKT, CR TPDU and
// an RDP_NEG_REQ asking for RDP | TLS | CredSSP | RDSTLS (0x0b).
const REQUEST = Buffer.from(
  '030000130ee0000000000001000800' + '0b000000', 'hex')

// What a live Windows answers: X.224 Connection Confirm, length 19.
const CONFIRM = Buffer.from('030000130ed00000123400020008000000' + '0000', 'hex')

// Starts a server, runs the probe against it, resolves to {status, received}.
function probe(handler, extra = {}) {
  return new Promise((resolve, reject) => {
    const chunks = []
    const sockets = []
    const server = net.createServer(socket => {
      sockets.push(socket)
      socket.on('data', data => { chunks.push(data); handler(socket, data) })
    })
    server.on('error', reject)
    server.listen(0, '127.0.0.1', async () => {
      const status = await rdpProbe(server.address().port, extra)
      server.close(() => resolve({ status, received: Buffer.concat(chunks) }))
      for (const socket of sockets) socket.destroy()
    })
  })
}

test('a Connection Confirm is success, and the request is the 19-byte form', async () => {
  const { status, received } = await probe(socket => { socket.end(CONFIRM) })
  assert.equal(status, 0)
  assert.equal(received.length, 19)
  assert.deepEqual(received, REQUEST)
})

test('requestedProtocols is overridable', async () => {
  const { status, received } = await probe(socket => { socket.end(CONFIRM) },
    { RDP_PROTOCOLS: '00000000' })
  assert.equal(status, 0)
  assert.deepEqual(received.subarray(15), Buffer.from('00000000', 'hex'))
})

test('a reply that is not a Connection Confirm fails', async () => {
  const garbage = Buffer.from('HTTP/1.1 400 Bad Re\n'.slice(0, 19))
  const { status } = await probe(socket => { socket.end(garbage) })
  assert.equal(status, 1)
})

test('a Connection Confirm of the wrong TPDU code fails', async () => {
  // 0xf0 (Data TPDU) where 0xd0 (CC) belongs: right length, wrong answer.
  const wrong = Buffer.from(CONFIRM)
  wrong[5] = 0xf0
  const { status } = await probe(socket => { socket.end(wrong) })
  assert.equal(status, 1)
})

test('an accepted connection that never answers times out and fails', async () => {
  const { status } = await probe(() => {}, { RDP_TIMEOUT: '1' })
  assert.equal(status, 1)
})

test('a closed port is refused, not a timeout', async () => {
  const port = await new Promise(resolve => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
  assert.equal(await rdpProbe(port), 2)
})

test('an unresolvable host is refused too', async () => {
  assert.equal(await rdpProbe(3389, { RDP_HOST: 'omawin.invalid' }), 2)
})
