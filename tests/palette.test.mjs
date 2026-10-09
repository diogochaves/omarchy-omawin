import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

// Qt 6.12's QtQuick exports its own Color type, which hides the shell's
// qs.Commons Color singleton: a bare Color.foreground comes out undefined.
// Every palette read has to go through the Commons alias.
test('QML reads the shell palette as Commons.Color', () => {
  const root = join(import.meta.dirname, '..')
  const bare = []
  for (const file of readdirSync(root).filter(name => name.endsWith('.qml'))) {
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, i) => {
      const code = line.replace(/\/\/.*$/, '')
      if (/(^|[^\w.])Color\./.test(code)) bare.push(`${file}:${i + 1}`)
    })
  }
  assert.deepEqual(bare, [])
})
