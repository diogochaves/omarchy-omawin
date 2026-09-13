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
