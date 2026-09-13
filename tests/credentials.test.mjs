import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper } from './helpers.mjs'

// helpers/credentials.sh against a throwaway ~/.config/windows/credentials and
// a sparse data.img. CREDS_DRY_RUN=1 skips the one privileged step (the same
// pkexec'd write_compose Tune uses) and leaves the file rewrite, which is the
// part that is ours: atomic, 0600, two lines, split on the first = only.
//
// Nothing here calls wl-copy: `copy` and `clear` are one pipe each into a
// clipboard that a test has no business owning.
const GIB = 1024 ** 3

function box(t, { disk = 64, credentials = 'USERNAME=chaves\nPASSWORD=secret\n' } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-creds-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const image = path.join(dir, 'data.img')
  if (disk > 0) {
    fs.writeFileSync(image, '')
    fs.truncateSync(image, disk * GIB)
  }
  const file = path.join(dir, 'credentials')
  if (credentials !== null) fs.writeFileSync(file, credentials, { mode: 0o600 })
  return {
    dir,
    file,
    env: { CREDENTIALS_FILE: file, DATA_IMAGE: image, TZ_NAME: 'UTC', CREDS_DRY_RUN: '1' },
    read: () => fs.readFileSync(file, 'utf8'),
    mode: () => fs.statSync(file).mode & 0o777
  }
}

function run(env, args, input) {
  return helper('credentials.sh', args, env, input)
}

function write(env, password, args = ['--cores', '6', '--ram', '16G']) {
  return run(env, ['write', ...args], password + '\n')
}

test('username and password print one line each, and only what was asked for', t => {
  const { env } = box(t)
  const user = run(env, ['username'])
  assert.equal(user.status, 0)
  assert.equal(user.out, 'chaves')
  assert.equal(user.out.includes('secret'), false)

  const password = run(env, ['password'])
  assert.equal(password.status, 0)
  assert.equal(password.out, 'secret')
})

test('a password that contains = and $ comes back whole', t => {
  // Both halves matter: the file is split on the FIRST = only (as
  // omarchy-windows-vm's read_credential does), and nothing expands $.
  const stored = 'a=b$c"d\\e f'
  const { env } = box(t, { credentials: 'USERNAME=chaves\nPASSWORD=' + stored + '\n' })
  assert.equal(run(env, ['password']).out, stored)
  assert.equal(run(env, ['username']).out, 'chaves')
})

test('a missing file, a missing line and an unusable value are all refusals', t => {
  const gone = box(t, { credentials: null })
  const missing = run(gone.env, ['password'])
  assert.equal(missing.status, 2)
  assert.match(missing.err, /no credentials at .*: run omarchy-windows-vm install first/)

  const noUser = box(t, { credentials: 'PASSWORD=secret\n' })
  assert.equal(run(noUser.env, ['username']).status, 2)

  const badUser = box(t, { credentials: 'USERNAME=na/me\nPASSWORD=secret\n' })
  assert.match(run(badUser.env, ['username']).err, /username is not a usable one/)

  // A stored password the writer would refuse is reported without quoting it.
  const badPassword = box(t, { credentials: 'USERNAME=chaves\nPASSWORD=' + 'x'.repeat(65) + '\n' })
  const result = run(badPassword.env, ['password'])
  assert.equal(result.status, 2)
  assert.match(result.err, /not a single printable line/)
  assert.equal(result.err.includes('xxx'), false)
})

test('write rewrites the file, keeps the username, and round-trips', t => {
  const { env, file, read, mode } = box(t)
  const next = 'c0rrect=horse$battery "staple"\\'
  const saved = write(env, next)
  assert.equal(saved.status, 0, saved.err)
  assert.equal(saved.out, 'dry run: compose not rewritten\nok')

  assert.equal(read(), 'USERNAME=chaves\nPASSWORD=' + next + '\n')
  assert.equal(mode(), 0o600)
  // Read back through the same first-= split the helper and the VM both use.
  assert.equal(run(env, ['password']).out, next)
  assert.equal(run(env, ['username']).out, 'chaves')
  // The temp file it renamed over is gone, and it was in the same directory.
  assert.deepEqual(fs.readdirSync(path.dirname(file)).filter(name => name.startsWith('.')), [])
})

test('write validates with the helper\'s own rule and changes nothing when it refuses', t => {
  const { env, read } = box(t)
  const before = read()
  const refused = [
    ['', /1 to 64 printable characters/],
    ['x'.repeat(65), /1 to 64 printable characters/],
    ['two\tlines', /1 to 64 printable characters/]
  ]
  for (const [password, message] of refused) {
    const result = write(env, password)
    assert.equal(result.status, 2, JSON.stringify(password))
    assert.match(result.err, message)
    assert.equal(read(), before, 'the file is untouched')
    assert.equal(result.err.includes(password) && password !== '', false, 'never quoted back')
  }
  // A 64-character password is the longest one it does take.
  assert.equal(write(env, 'y'.repeat(64)).status, 0)
})

test('write needs the shape the compose has to be rewritten with', t => {
  const { env, read } = box(t)
  const before = read()
  const noShape = run(env, ['write'], 'whatever\n')
  assert.equal(noShape.status, 2)
  assert.match(noShape.err, /core count is not known yet/)

  const noRam = run(env, ['write', '--cores', '6'], 'whatever\n')
  assert.equal(noRam.status, 2)
  assert.match(noRam.err, /RAM size is not known yet/)

  const badShape = run(env, ['write', '--cores', '0', '--ram', '16G'], 'whatever\n')
  assert.equal(badShape.status, 2)

  // No data.img, no DISK_SIZE to pass through: the writer takes all six fields
  // or none, so this is a refusal rather than a guess.
  const fresh = box(t, { disk: 0 })
  const noDisk = write(fresh.env, 'whatever')
  assert.equal(noDisk.status, 2)
  assert.match(noDisk.err, /cannot read the disk size of/)

  assert.equal(read(), before)
})

test('the usage line is what an unknown subcommand gets', () => {
  const result = helper('credentials.sh', ['rotate'])
  assert.equal(result.status, 2)
  assert.match(result.err, /usage: credentials\.sh username \| password \| copy \| clear \| write/)
})
