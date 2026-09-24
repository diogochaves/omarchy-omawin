import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper } from './helpers.mjs'

// helpers/tune.sh, unprivileged, against a throwaway credentials file and a
// sparse data.img. Every reading it would take from the machine — nproc,
// MemTotal, df, timedatectl — is stood in for by the hooks in its header, and
// TUNE_DRY_RUN=1 stops at the pkexec call and prints the six lines it would
// have piped into it, with the password replaced by ***. So the guards, the
// validation and the payload are all exercised without a VM, without root and
// without ever putting a password anywhere a test could read it.
const GIB = 1024 ** 3

function box(t, { disk = 64, credentials = 'USERNAME=chaves\nPASSWORD=secret\n' } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-tune-'))
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
    env: {
      CREDENTIALS_FILE: file,
      DATA_IMAGE: image,
      LEGACY_COMPOSE_FILE: path.join(dir, 'legacy-compose.yml'),
      WINDOWS_DIR: dir,
      HOST_CORES: '8',
      HOST_RAM_GB: '32',
      FREE_GB: '412',
      TZ_NAME: 'Europe/Lisbon'
    }
  }
}

function limits(env, extra = {}) {
  return helper('tune.sh', ['limits'], { ...env, ...extra })
}

function apply(env, args, extra = {}) {
  return helper('tune.sh', ['apply', ...args], { TUNE_DRY_RUN: '1', ...env, ...extra })
}

const SHAPE = ['--cores', '6', '--ram', '16G', '--disk', '96G']

test('limits prints the four readings the Tune face draws itself from', t => {
  const { env } = box(t)
  const { status, out } = limits(env)
  assert.equal(status, 0)
  assert.equal(out, 'cores=8 ram=32 free=412 disk=64G login=chaves')
})

test('limits leaves a reading blank rather than guessing at it', t => {
  const { env } = box(t, { disk: 0, credentials: 'PASSWORD=secret\n' })
  const { status, out } = limits(env, { HOST_CORES: '', HOST_RAM_GB: '', FREE_GB: '' })
  assert.equal(status, 0)
  assert.equal(out, 'cores= ram= free= disk= login=')
})

test('apply pipes the six fields the writer wants, and the password only there', t => {
  const { env } = box(t)
  const { status, out, err } = apply(env, SHAPE)
  assert.equal(status, 0, err)
  assert.equal(out, [
    'RAM=16G', 'CORES=6', 'DISK=96G', 'USERNAME=chaves', 'PASSWORD=***',
    'TZ=Europe/Lisbon', 'ok'
  ].join('\n'))
  // Not even the dry run prints it, and nothing it writes carries it either.
  assert.equal(out.includes('secret'), false)
  assert.equal(err.includes('secret'), false)
})

test('a password with = and $ in it reaches the writer, and is still not printed', t => {
  // The credentials file is split on the FIRST = only, like the helper's own
  // read_credential, so this is one password and not a truncated one.
  const { env } = box(t, { credentials: 'USERNAME=chaves\nPASSWORD=a=b$c"d\\e\n' })
  const { status, out } = apply(env, SHAPE)
  assert.equal(status, 0)
  assert.match(out, /^PASSWORD=\*\*\*$/m)
  assert.equal(out.includes('a=b'), false)
})

test('the disk grows and never shrinks', t => {
  const { env } = box(t, { disk: 64 })
  const shrink = apply(env, ['--cores', '6', '--ram', '16G', '--disk', '32G'])
  assert.equal(shrink.status, 2)
  assert.match(shrink.err, /cannot shrink: data\.img is already 64G/)
  assert.equal(shrink.out, '')

  // The same size is not a shrink, and neither is a bigger one.
  assert.equal(apply(env, ['--cores', '6', '--ram', '16G', '--disk', '64G']).status, 0)
  assert.equal(apply(env, ['--cores', '6', '--ram', '16G', '--disk', '512G'],
    { FREE_GB: '9000' }).status, 0)

  // With no image yet there is nothing to shrink below.
  const fresh = box(t, { disk: 0 })
  assert.equal(apply(fresh.env, ['--cores', '6', '--ram', '16G', '--disk', '32G']).status, 0)
})

test('the wizard\'s free-space rule is applied the way the wizard applies it', t => {
  const { env } = box(t)
  // 96 + 10 = 106 GB wanted. One less than that is a refusal, and the image
  // already on disk is deliberately NOT subtracted — this is install's own sum.
  const tight = apply(env, SHAPE, { FREE_GB: '105' })
  assert.equal(tight.status, 2)
  assert.match(tight.err, /not enough room: 96G needs 106 GB free \(disk \+ 10 GB\), 105 GB left/)
  assert.equal(apply(env, SHAPE, { FREE_GB: '106' }).status, 0)
  // An unreadable df is not a refusal: the writer is the one that must agree.
  assert.equal(apply(env, SHAPE, { FREE_GB: '' }).status, 0)
})

test('the machine caps the cores and the RAM', t => {
  const { env } = box(t)
  const cores = apply(env, ['--cores', '9', '--ram', '16G', '--disk', '96G'])
  assert.equal(cores.status, 2)
  assert.match(cores.err, /9 cores is more than the 8 this machine has/)

  const ram = apply(env, ['--cores', '6', '--ram', '64G', '--disk', '96G'])
  assert.equal(ram.status, 2)
  assert.match(ram.err, /64G is more RAM than this machine has \(32G\)/)

  assert.equal(apply(env, ['--cores', '8', '--ram', '32G', '--disk', '96G']).status, 0)
})

test('every field is checked against the root writer\'s own regexes first', t => {
  const { env } = box(t)
  const refused = [
    [['--cores', '0', '--ram', '16G', '--disk', '96G'], /not a number of cores: 0/],
    [['--cores', '1e1', '--ram', '16G', '--disk', '96G'], /not a number of cores/],
    [['--cores', '6', '--ram', '16', '--disk', '96G'], /not a RAM size: 16/],
    [['--cores', '6', '--ram', '16GB', '--disk', '96G'], /not a RAM size/],
    [['--cores', '6', '--ram', '16G', '--disk', '96'], /not a disk size: 96/],
    [['--cores', '6', '--ram', '16G', '--disk', '99999G'], /not a disk size/],
    [['--cores', '6', '--ram', '16G'], /not a disk size/],
    [['--cores'], /--cores needs a value/],
    [['--shell', 'x'], /unknown option: --shell/]
  ]
  for (const [args, message] of refused) {
    const result = apply(env, args)
    assert.equal(result.status, 2, args.join(' '))
    assert.match(result.err, message)
    assert.equal(result.out, '')
  }
})

test('without a credentials file there is no login to pass through', t => {
  const { env } = box(t, { credentials: null })
  const missing = apply(env, SHAPE)
  assert.equal(missing.status, 2)
  assert.match(missing.err, /no credentials at .*: run omarchy-windows-vm install first/)

  // A stored login the writer would refuse is caught here, before the dialog.
  const bad = box(t, { credentials: 'USERNAME=na/me\nPASSWORD=secret\n' })
  const result = apply(bad.env, SHAPE)
  assert.equal(result.status, 2)
  assert.match(result.err, /username is not one the VM writer accepts/)

  // And so is a password the writer would refuse — without quoting it back.
  const long = box(t, { credentials: 'USERNAME=chaves\nPASSWORD=' + 'x'.repeat(65) + '\n' })
  const tooLong = apply(long.env, SHAPE)
  assert.equal(tooLong.status, 2)
  assert.match(tooLong.err, /not a single printable line/)
  assert.equal(tooLong.err.includes('xxx'), false)
})

test('an unusable timezone falls back to UTC, as the helper does', t => {
  const { env } = box(t)
  assert.match(apply(env, SHAPE, { TZ_NAME: 'Mars/Olympus Mons' }).out, /^TZ=UTC$/m)
  assert.match(apply(env, SHAPE, { TZ_NAME: '' }).out, /^TZ=UTC$/m)
})

test('the usage line is what an unknown subcommand gets', () => {
  const result = helper('tune.sh', ['upgrade'])
  assert.equal(result.status, 2)
  assert.match(result.err, /usage: tune\.sh limits \| tune\.sh apply/)
})

test('an install Omarchy has not moved yet is told to start once, not to reinstall', t => {
  const { dir, env } = box(t, { credentials: null })
  fs.writeFileSync(path.join(dir, 'legacy-compose.yml'), 'services:\n')
  const result = apply(env, ['--cores', '4', '--ram', '8G', '--disk', '64G'], { TUNE_DRY_RUN: '1' })
  assert.equal(result.status, 2)
  assert.match(result.err, /start the VM once first/)
})
