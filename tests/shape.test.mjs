import assert from 'node:assert/strict'
import test from 'node:test'
import { load } from './helpers.mjs'

const State = load('lib/State.js')
const line = (over = {}) => {
  const f = { installed: '1', docker: 'active', pid: '1360395', frozen: '0', cores: '4', ram: '16G',
    web: '401', cid: '3fff20be7c1d', started: '1757555121', ...over }
  return Object.entries(f).map(([k, v]) => `${k}=${v}`).join(' ')
}

// The sampler prints fixed shapes; anything else is dropped field by field,
// so a garbled line can blank a reading but never put text on the card.
test('parseSample keeps only well-shaped fields', () => {
  const ok = State.parseSample(line())
  assert.equal(ok.ram, '16G')
  assert.equal(ok.cid, '3fff20be7c1d')
  assert.equal(ok.docker, 'active')
  assert.equal(ok.cores, 4)

  assert.equal(State.parseSample(line({ ram: '16G<img src=x>' })).ram, '')
  assert.equal(State.parseSample(line({ ram: '9999999G' })).ram, '')
  assert.equal(State.parseSample(line({ cid: 'not-hex' })).cid, '')
  assert.equal(State.parseSample(line({ docker: 'Active!' })).docker, '')
  assert.equal(State.parseSample(line({ cores: '4096' })).cores, 0)
  assert.equal(State.parseSample(line({ cores: '1024' })).cores, 1024)
})

test('RAM_SHAPE is what the cache reader checks too', () => {
  assert.equal(State.RAM_SHAPE.test('16G'), true)
  assert.equal(State.RAM_SHAPE.test('8192M'), true)
  assert.equal(State.RAM_SHAPE.test('16 GB'), false)
})

// The two shapes added with Tune are the VM writer's own: valid_disk's NNNNG
// and valid_username's twenty characters. Panel.qml checks a chip against them
// before it is offered and Service.qml before it is sent, so they are the same
// rule on both sides of the pkexec call.
test('DISK_SHAPE and LOGIN_SHAPE are the writer\'s own rules', () => {
  for (const good of ['32G', '64G', '512G', '1024G']) {
    assert.equal(State.DISK_SHAPE.test(good), true, good)
  }
  for (const bad of ['64', '64GB', '12345G', '64g', '', '64G ']) {
    assert.equal(State.DISK_SHAPE.test(bad), false, JSON.stringify(bad))
  }
  for (const good of ['chaves', 'docker', 'a-b_C9', 'x'.repeat(20)]) {
    assert.equal(State.LOGIN_SHAPE.test(good), true, good)
  }
  for (const bad of ['', 'na/me', 'na me', 'x'.repeat(21), 'näme']) {
    assert.equal(State.LOGIN_SHAPE.test(bad), false, JSON.stringify(bad))
  }
})

test('the sampler\'s own line parses into the shapes the panel prints', () => {
  // The 0.2.0 line, end to end: the two new fields are read, and a garbled one
  // loses the field rather than the line.
  const full = line({ disk: '64G', login: 'chaves' })
  assert.equal(State.parseSample(full).disk, '64G')
  assert.equal(State.parseSample(full).login, 'chaves')
  assert.equal(State.parseSample(line({ disk: '64', login: 'chaves' })).pid, 1360395)
  assert.equal(State.parseSample(line({ disk: '64', login: 'chaves' })).disk, '')
})
