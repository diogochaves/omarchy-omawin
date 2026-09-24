import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import test from 'node:test'
import { root } from './helpers.mjs'

// Every tracked shell script is shellcheck-clean (tests/shellcheck.sh picks
// them; .shellcheckrc holds the settings). Skipped, not failed, where
// shellcheck is not installed.
const found = spawnSync('shellcheck', ['--version']).status === 0

test('shell is shellcheck-clean', { skip: !found && 'shellcheck not installed' }, () => {
  const result = spawnSync(path.join(root, 'tests', 'shellcheck.sh'), { cwd: root, encoding: 'utf8' })
  assert.equal(result.status, 0, result.stdout + result.stderr)
})
