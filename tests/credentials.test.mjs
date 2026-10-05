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
// Nothing here calls the real wl-copy: `copy` and `clear` are tested against a
// stand-in clipboard (WL_COPY/WL_PASTE), a plain file in the test directory.
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
    env: {
      CREDENTIALS_FILE: file, DATA_IMAGE: image, TZ_NAME: 'UTC', CREDS_DRY_RUN: '1',
      LEGACY_COMPOSE_FILE: path.join(dir, 'legacy-compose.yml'),
      ...clipboard(dir)
    },
    read: () => fs.readFileSync(file, 'utf8'),
    mode: () => fs.statSync(file).mode & 0o777
  }
}

// A clipboard that is a file: wl-copy writes stdin to it (or empties it on
// --clear) and logs its arguments, wl-paste prints it.
function clipboard(dir) {
  const board = path.join(dir, 'clipboard')
  const copy = path.join(dir, 'wl-copy')
  const paste = path.join(dir, 'wl-paste')
  fs.writeFileSync(copy, `#!/bin/bash
echo "$*" >>'${board}.log'
if [[ $1 == --clear ]]; then : >'${board}'; else cat >'${board}'; fi
`, { mode: 0o755 })
  fs.writeFileSync(paste, `#!/bin/bash
[[ -s '${board}' ]] || exit 1
cat '${board}'
`, { mode: 0o755 })
  return { WL_COPY: copy, WL_PASTE: paste, COPY_MARK: path.join(dir, 'run/copied') }
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
  assert.equal(saved.out, 'dry run: compose not rewritten (RAM=16G CORES=6 DISK=64G)\nok')

  assert.equal(read(), 'USERNAME=chaves\nPASSWORD=' + next + '\n')
  assert.equal(mode(), 0o600)
  // Read back through the same first-= split the helper and the VM both use.
  assert.equal(run(env, ['password']).out, next)
  assert.equal(run(env, ['username']).out, 'chaves')
  // The temp file it renamed over is gone, and it was in the same directory.
  assert.deepEqual(fs.readdirSync(path.dirname(file)).filter(name => name.startsWith('.')), [])
})

// Update login: another existing Windows account, with or without a new
// password. The username is Omarchy's own rule; the kept password is the
// stored one, and the stdin line is read and dropped either way.
test('write can change the username and keep the stored password', t => {
  const { env, read } = box(t, { credentials: 'USERNAME=chaves\nPASSWORD=s3cret=x\n' })
  const both = write(env, 'n3w', ['--cores', '6', '--ram', '16G', '--username', 'diogo'])
  assert.equal(both.status, 0, both.err)
  assert.equal(read(), 'USERNAME=diogo\nPASSWORD=n3w\n')

  const kept = write(env, '', ['--cores', '6', '--ram', '16G', '--username', 'Other_1', '--keep-password'])
  assert.equal(kept.status, 0, kept.err)
  assert.equal(read(), 'USERNAME=Other_1\nPASSWORD=n3w\n')

  // Whatever arrives on stdin is not used when the password is kept.
  assert.equal(write(env, 'ignored', ['--cores', '6', '--ram', '16G', '--keep-password']).status, 0)
  assert.equal(read(), 'USERNAME=Other_1\nPASSWORD=n3w\n')
})

test('a username Omarchy would refuse changes nothing', t => {
  const { env, read } = box(t)
  for (const name of ['two words', 'a.b', 'x'.repeat(21), 'ação', 'x=y']) {
    const result = write(env, 'n3w', ['--cores', '6', '--ram', '16G', '--username', name])
    assert.equal(result.status, 2, name)
    assert.match(result.err, /letters, digits, _ and -, up to 20/)
  }
  assert.equal(read(), 'USERNAME=chaves\nPASSWORD=secret\n')
  assert.equal(write(env, 'n3w', ['--cores', '6', '--ram', '16G', '--username']).status, 2)
})

test('keeping a password needs one stored', t => {
  const { env } = box(t, { credentials: 'USERNAME=chaves\n' })
  const result = write(env, '', ['--cores', '6', '--ram', '16G', '--username', 'diogo', '--keep-password'])
  assert.equal(result.status, 2)
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

test('a password Omarchy would read back shorter is refused', t => {
  // The helper's read_credential splits with IFS='=' read, which drops a
  // trailing = that is the password's only one. Those are refused whole...
  const { env, read } = box(t)
  const before = read()
  for (const password of ['Secret1=', '=']) {
    const result = write(env, password)
    assert.equal(result.status, 2, password)
    assert.match(result.err, /only = is its last character/)
    assert.equal(read(), before, 'the file is untouched')
  }
  // ...and every other = survives, so those are taken.
  for (const password of ['x==', 'a=b=', '==', 'a=b']) {
    assert.equal(write(env, password).status, 0, password)
    assert.equal(run(env, ['password']).out, password)
  }
})

test('a password with non-ASCII letters is printable, as it is to the helper', t => {
  // Omarchy validates in C.UTF-8 (root side) and the user's UTF-8 locale (the
  // wizard), so a VM can be installed with one: it must not be refused here.
  const { env, read } = box(t, { credentials: 'USERNAME=chaves\nPASSWORD=Pässwort1\n' })
  assert.equal(run(env, ['password']).out, 'Pässwort1')
  const copied = run(env, ['copy'])
  assert.equal(copied.status, 0, copied.err)

  // 64 characters is the limit, counted as characters and not bytes.
  const umlauts = 'ä'.repeat(64)
  const saved = write(env, umlauts)
  assert.equal(saved.status, 0, saved.err)
  assert.equal(read(), 'USERNAME=chaves\nPASSWORD=' + umlauts + '\n')
  const long = write(env, umlauts + 'x')
  assert.equal(long.status, 2)
  assert.match(long.err, /1 to 64 printable characters/)
  // A byte that is not UTF-8 at all is still refused.
  assert.equal(helper('credentials.sh', ['write', '--cores', '6', '--ram', '16G'], env,
    Buffer.from([0x61, 0xff, 0x0a])).status, 2)
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

test('write keeps a pending disk grow, and never shrinks the disk', t => {
  // Tune 64G -> 96G, not started yet: the compose already says 96G while
  // data.img is still 64G. Saving a password must write 96G back, not 64G.
  const { env, read } = box(t)
  const grown = write(env, 'next', ['--cores', '6', '--ram', '16G', '--disk', '96G'])
  assert.equal(grown.status, 0, grown.err)
  assert.match(grown.out, /DISK=96G\)/)

  // Without --disk, it is data.img's own size.
  assert.match(write(env, 'next').out, /DISK=64G\)/)

  const before = read()
  const shrink = write(env, 'other', ['--cores', '6', '--ram', '16G', '--disk', '32G'])
  assert.equal(shrink.status, 2)
  assert.match(shrink.err, /the disk cannot shrink: data\.img is already 64G/)

  const junk = write(env, 'other', ['--cores', '6', '--ram', '16G', '--disk', '—'])
  assert.equal(junk.status, 2)
  assert.match(junk.err, /not a disk size/)
  assert.equal(read(), before, 'a refusal leaves the file alone')
})

test('an install Omarchy has not moved yet is told to start once, not to reinstall', t => {
  const { dir, env } = box(t, { credentials: null })
  fs.writeFileSync(path.join(dir, 'legacy-compose.yml'), 'services:\n')
  for (const args of [['username'], ['password']]) {
    const result = run(env, args)
    assert.equal(result.status, 2)
    assert.match(result.err, /start the VM once first/)
  }
})

test('copy puts the password on the clipboard marked sensitive, and notes only a digest', t => {
  const { dir, env } = box(t)
  const copied = run(env, ['copy'])
  assert.equal(copied.status, 0, copied.err)
  assert.equal(fs.readFileSync(path.join(dir, 'clipboard'), 'utf8'), 'secret')
  assert.equal(fs.readFileSync(path.join(dir, 'clipboard.log'), 'utf8'), '--sensitive --type text/plain\n')
  const mark = fs.readFileSync(path.join(dir, 'run/copied'), 'utf8')
  assert.match(mark, /^[0-9a-f]{64}\n$/)
  assert.equal(mark.includes('secret'), false)
  assert.equal(fs.statSync(path.join(dir, 'run/copied')).mode & 0o777, 0o600)
})

test('clear empties the clipboard only while it still holds what copy put there', t => {
  const { dir, env } = box(t)
  const board = path.join(dir, 'clipboard')
  run(env, ['copy'])
  assert.equal(run(env, ['clear']).status, 0)
  assert.equal(fs.readFileSync(board, 'utf8'), '')
  assert.equal(fs.existsSync(path.join(dir, 'run/copied')), false, 'the note is used up')

  // The user copied something else since: theirs, left alone.
  run(env, ['copy'])
  fs.writeFileSync(board, 'something of mine')
  run(env, ['clear'])
  assert.equal(fs.readFileSync(board, 'utf8'), 'something of mine')

  // The password was changed after the copy (Update password within the 30 s):
  // the OLD one is still on the clipboard and is still cleared.
  run(env, ['copy'])
  assert.equal(write(env, 'a new one').status, 0)
  run(env, ['clear'])
  assert.equal(fs.readFileSync(board, 'utf8'), '')

  // Nothing copied by us, nothing cleared.
  fs.writeFileSync(board, 'secret')
  run(env, ['clear'])
  assert.equal(fs.readFileSync(board, 'utf8'), 'secret')
})

test('the usage line is what an unknown subcommand gets', () => {
  const result = helper('credentials.sh', ['rotate'])
  assert.equal(result.status, 2)
  assert.match(result.err, /usage: credentials\.sh username \| password \| copy \| clear \| write/)
})
