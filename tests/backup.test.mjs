import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper, root } from './helpers.mjs'

// helpers/backup.sh against a throwaway home: a ~/.windows with a sparse
// data.img that has a little written to it, and a credentials file.
// FREE_BYTES and REFLINK stand in for df and the filesystem type.
const MIB = 1024 * 1024

function box(t, { written = 1, credentials = true } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-backup-'))
  t.after(() => fs.rmSync(home, { recursive: true, force: true }))
  const windows = path.join(home, '.windows')
  fs.mkdirSync(windows)
  const image = path.join(windows, 'data.img')
  fs.writeFileSync(image, '')
  fs.truncateSync(image, 64 * 1024 ** 3)
  const fd = fs.openSync(image, 'r+')
  const chunk = Buffer.alloc(MIB, 7)
  for (let i = 0; i < written; i++) fs.writeSync(fd, chunk, 0, MIB, i * MIB)
  fs.closeSync(fd)
  fs.writeFileSync(path.join(windows, 'windows.ver'), '11\n')
  const creds = path.join(home, 'credentials')
  if (credentials) fs.writeFileSync(creds, 'USERNAME=chaves\nPASSWORD=secret\n', { mode: 0o600 })
  return {
    home,
    env: {
      WINDOWS_DIR: windows, CREDENTIALS_FILE: creds, BACKUP_ROOT: home,
      TODAY: '2026-10-04', FREE_BYTES: String(500 * 1024 ** 3), REFLINK: '0'
    }
  }
}

const fields = line => Object.fromEntries(line.split(' ').map(pair => pair.split('=')))

test('plan says what the copy takes and where it goes', t => {
  const { env, home } = box(t, { written: 3 })
  const plan = helper('backup.sh', ['plan'], env)
  assert.equal(plan.status, 0, plan.err)
  const f = fields(plan.out)
  assert.equal(f.ok, '1')
  assert.equal(f.reflink, '0')
  assert.equal(f.target, '.windows.bak-2026-10-04')
  assert.equal(f.last, '')
  // What Windows wrote, not the 64G the sparse image claims.
  assert.ok(Number(f.used) >= 3 * MIB && Number(f.used) < 64 * MIB, f.used)

  fs.mkdirSync(path.join(home, '.windows.bak-2026-10-04'))
  const again = fields(helper('backup.sh', ['plan'], env).out)
  assert.equal(again.target, '.windows.bak-2026-10-04-2')
  assert.match(again.last, /^[0-9]+$/)
})

test('no room for a full copy is ok=0, and run refuses it', t => {
  const { env, home } = box(t, { written: 2 })
  const tight = { ...env, FREE_BYTES: String(1024 ** 3) }
  assert.equal(fields(helper('backup.sh', ['plan'], tight).out).ok, '0')
  // A reflink copy only needs room for the metadata.
  assert.equal(fields(helper('backup.sh', ['plan'], { ...tight, REFLINK: '1' }).out).ok, '1')
  const refused = helper('backup.sh', ['run'], tight)
  assert.equal(refused.status, 2)
  assert.match(refused.err, /not enough room/)
  assert.deepEqual(fs.readdirSync(home).filter(n => n.startsWith('.windows.bak')), [])
})

test('run copies the disk, sparse, and the login, 0600', t => {
  const { env, home } = box(t, { written: 2 })
  const result = helper('backup.sh', ['run'], env)
  assert.equal(result.status, 0, result.err)
  assert.match(result.out, /copied=[0-9]+/)
  assert.match(result.out, /\ndone=\.windows\.bak-2026-10-04$/)
  const backup = path.join(home, '.windows.bak-2026-10-04')
  const image = fs.statSync(path.join(backup, 'windows/data.img'))
  assert.equal(image.size, 64 * 1024 ** 3)
  assert.ok(image.blocks * 512 < 64 * MIB, 'the copy stays sparse')
  assert.equal(fs.readFileSync(path.join(backup, 'windows/windows.ver'), 'utf8'), '11\n')
  assert.equal(fs.readFileSync(path.join(backup, 'credentials'), 'utf8'), 'USERNAME=chaves\nPASSWORD=secret\n')
  assert.equal(fs.statSync(path.join(backup, 'credentials')).mode & 0o777, 0o600)
  assert.deepEqual(fs.readdirSync(home).filter(n => n.includes('partial') || n.includes('errors')), [])
})

test('a ~/.windows that is a symlink is measured and copied where it points', t => {
  const { env, home } = box(t, { written: 3 })
  const real = path.join(home, 'elsewhere')
  fs.renameSync(env.WINDOWS_DIR, real)
  fs.symlinkSync(real, env.WINDOWS_DIR)
  assert.ok(Number(fields(helper('backup.sh', ['plan'], env).out).used) >= 3 * MIB)
  const result = helper('backup.sh', ['run'], env)
  assert.equal(result.status, 0, result.err)
  const copy = path.join(home, '.windows.bak-2026-10-04/windows')
  assert.equal(fs.lstatSync(copy).isDirectory(), true)
  assert.equal(fs.statSync(path.join(copy, 'data.img')).size, 64 * 1024 ** 3)
})

test('no VM, no backup', t => {
  const { env, home } = box(t)
  fs.rmSync(path.join(home, '.windows'), { recursive: true })
  const result = helper('backup.sh', ['plan'], env)
  assert.equal(result.status, 2)
  assert.match(result.err, /no VM to back up/)
})

// Cancel is a SIGTERM to the helper: the copy stops and the half-made folder
// goes, so nothing that looks like a backup is left.
test('a cancelled copy leaves nothing behind', async t => {
  const { env, home } = box(t, { written: 768 })
  const child = spawn('/bin/bash', [path.join(root, 'helpers/backup.sh'), 'run'],
    { env: { ...process.env, LC_ALL: 'C', ...env } })
  let out = ''
  await new Promise(resolve => child.stdout.on('data', data => {
    out += data
    if (out.includes('copied=')) resolve()
  }))
  child.kill('SIGTERM')
  const code = await new Promise(resolve => child.on('exit', (c, signal) => resolve(c ?? signal)))
  assert.notEqual(code, 0)
  assert.equal(out.includes('done='), false, 'the copy finished before the cancel landed')
  assert.deepEqual(fs.readdirSync(home).filter(n => n.startsWith('.windows.bak')), [])
})
