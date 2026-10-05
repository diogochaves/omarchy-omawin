import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper } from './helpers.mjs'

// helpers/key-binding.sh against a throwaway bindings.lua: it reads the one
// line that binds `chaves.omawin primary` and never runs anything.
function key(t, text) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-keys-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const file = path.join(dir, 'bindings.lua')
  if (text !== null) fs.writeFileSync(file, text)
  return helper('key-binding.sh', [], { HYPR_BINDINGS: file })
}

const LINE = 'o.bind("SUPER + ALT + W", "Windows VM", "omarchy-shell chaves.omawin primary")'

test('finds the key bound to primary, as Omarchy writes it', t => {
  const result = key(t, '-- my keys\no.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh x")\n' + LINE + '\n')
  assert.equal(result.status, 0)
  assert.equal(result.out, 'SUPER + ALT + W')
  // Spacing and case are the user's; the card prints one form.
  assert.equal(key(t, '  o.bind( "super+alt+F12" , nil, "omarchy-shell chaves.omawin primary")').out,
    'SUPER + ALT + F12')
  assert.equal(key(t, 'hl.bind("SUPER + CTRL + KP_1", "x", "omarchy-shell chaves.omawin primary")').out,
    'SUPER + CTRL + KP_1')
})

test('nothing for no file, no line, a comment or another command', t => {
  assert.equal(key(t, null).out, '')
  assert.equal(key(t, '').out, '')
  assert.equal(key(t, '-- ' + LINE + '\n').out, '')
  assert.equal(key(t, '    -- ' + LINE + '\n').out, '')
  assert.equal(key(t, 'o.bind("SUPER + W", "x", "omarchy-shell chaves.omawin toggle")\n').out, '')
  assert.equal(key(t, 'o.bind("SUPER + W", "x", "omarchy-shell chaves.sysmon primary")\n').out, '')
})

test('the last binding wins, and a key that is not plain names is dropped', t => {
  assert.equal(key(t, LINE + '\n' + LINE.replace('ALT + W', 'ALT + Q') + '\n').out, 'SUPER + ALT + Q')
  assert.equal(key(t, LINE + '\n' + LINE.replace('SUPER + ALT + W', 'SUPER + $(reboot)') + '\n').out,
    'SUPER + ALT + W')
  assert.equal(key(t, LINE.replace('SUPER + ALT + W', '<b>W</b>')).out, '')
  assert.equal(key(t, LINE.replace('SUPER + ALT + W', 'SUPER ++ W')).out, '')
})
