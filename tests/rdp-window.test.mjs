import assert from 'node:assert/strict'
import test from 'node:test'
import { helper } from './helpers.mjs'

// helpers/rdp-window.sh's pick: which window, from `hyprctl clients -j`, a
// middle click brings forward while a session is up. Only the RDP window
// Omarchy's launcher titles, and only an address Hyprland would accept.
function pick(clients) {
  const input = typeof clients === 'string' ? clients : JSON.stringify(clients)
  return helper('rdp-window.sh', ['pick'], {}, input)
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

// rdp-window.sh's caps: xfreerdp makes its window resizable the moment
// Windows opens the Display Control channel, and fit waits for that.
function caps(text) {
  return helper('rdp-window.sh', ['caps'], {}, text).out
}

test('caps: open once the window is resizable, waiting before', () => {
  const before = 'WM_NORMAL_HINTS(WM_SIZE_HINTS):\n\t\tprogram specified minimum size: 1 by 1\n\t\tprogram specified maximum size: 16384 by 16384\n'
  const after = 'WM_NORMAL_HINTS(WM_SIZE_HINTS):\n\t\tprogram specified minimum size: 320 by 320\n\t\tprogram specified maximum size: 8192 by 8192\n\t\twindow gravity: NorthWest\n'
  assert.equal(caps(before), 'waiting')
  assert.equal(caps(after), 'open')
  assert.equal(caps(''), 'waiting')
  assert.equal(caps('xprop: error: Can\'t open display\n'), 'waiting')
})

test('an unknown mode is a usage error', () => {
  assert.equal(helper('rdp-window.sh', [], {}).status, 2)
  assert.equal(helper('rdp-window.sh', ['nudge'], {}).status, 2)
})
