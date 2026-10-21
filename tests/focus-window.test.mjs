import assert from 'node:assert/strict'
import test from 'node:test'
import { helper } from './helpers.mjs'

// helpers/focus-window.sh's pick: which window, from `hyprctl clients -j`, a
// middle click brings forward while a session is up. Only the RDP window
// Omarchy's launcher titles, and only an address Hyprland would accept.
function pick(clients) {
  const input = typeof clients === 'string' ? clients : JSON.stringify(clients)
  return helper('focus-window.sh', ['pick'], {}, input)
}

const RDP = { title: 'Windows VM - Omarchy', class: 'xfreerdp', address: '0x55d0c3a1b2c0' }

test('finds the Windows window among the others', () => {
  const result = pick([
    { title: 'Windows VM - Omarchy notes.md', class: 'Alacritty', address: '0x1' },
    RDP,
    { title: 'Windows VM - Omarchy', class: 'xfreerdp', address: '0x2' }
  ])
  assert.equal(result.status, 0)
  assert.equal(result.out, RDP.address)
})

test('nothing when the window is not open yet, or the list is not a list', () => {
  assert.equal(pick([]).out, '')
  assert.equal(pick([{ title: 'Windows VM', address: '0x1' }]).out, '')
  assert.equal(pick('').out, '')
  assert.equal(pick('not json').status, 0)
  assert.equal(pick('not json').out, '')
  assert.equal(pick({ title: RDP.title, address: RDP.address }).out, '')
})

test('an address that is not plain hex is never dispatched', () => {
  assert.equal(pick([{ ...RDP, address: '0x1" }) hl.exec("x' }]).out, '')
  assert.equal(pick([{ ...RDP, address: 12 }]).out, '')
})
