import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper, root } from './helpers.mjs'

// helpers/backup.sh against a throwaway home: a ~/.windows with a sparse
// data.img that has a little written to it, and a credentials file.
// FREE_BYTES and REFLINK stand in for df and the filesystem type.
const MIB = 1024 * 1024

function box(t, { written = 1, credentials = true, under = os.tmpdir() } = {}) {
  const home = fs.mkdtempSync(path.join(under, 'omawin-backup-'))
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
  assert.equal(result.status, 3)
  assert.match(result.err, /nothing to back up yet/)
})

// Installed but never started: dockur makes data.img on the first boot, so
// there is a ~/.windows without one. Status 3, which the card reads as
// "nothing to back up yet" instead of a plan still loading (#28).
test('a VM that never started has nothing to back up yet', t => {
  const { env, home } = box(t)
  fs.rmSync(path.join(home, '.windows', 'data.img'))
  for (const verb of ['plan', 'run']) {
    const result = helper('backup.sh', [verb], env)
    assert.equal(result.status, 3, verb)
    assert.match(result.err, /nothing to back up yet: .* has no data\.img until Windows first starts/)
  }
  assert.deepEqual(fs.readdirSync(home).filter(n => n.startsWith('.windows.bak')), [])
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

// dockur's data.img is +C, and btrfs shares extents only between files that
// agree on it, so a +C image copied into a plain folder is a full copy (#30).
// A folder that refuses +C: the copy is a full one, so run checks the room
// for one, even though plan counted on sharing.
test('a +C image whose copy cannot be +C needs the room for a full copy', t => {
  const { env, home } = box(t, { written: 2 })
  const nocow = { ...env, REFLINK: '1', NOCOW: '1', NOCOW_SET: '0' }
  const tight = { ...nocow, FREE_BYTES: String(1024 ** 3) }
  assert.equal(fields(helper('backup.sh', ['plan'], tight).out).ok, '1')
  const refused = helper('backup.sh', ['run'], tight)
  assert.equal(refused.status, 2)
  assert.match(refused.err, /not enough room: .* can't turn copy-on-write off/)
  assert.deepEqual(fs.readdirSync(home).filter(n => n.startsWith('.windows.bak')), [])
  // With the room, it makes the full copy.
  const result = helper('backup.sh', ['run'], nocow)
  assert.equal(result.status, 0, result.err)
  assert.match(result.out, /\ndone=\.windows\.bak-2026-10-04$/)
})

// The real thing, where a btrfs folder is at hand (OMAWIN_TEST_BTRFS, or
// ~/.cache when it is on btrfs, as on Omarchy): a +C image comes out +C, its
// blocks shared with the original, and plan says so without the overrides.
function btrfsDir() {
  const candidates = [process.env.OMAWIN_TEST_BTRFS,
    path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'))]
  for (const dir of candidates) {
    if (!dir) continue
    const type = spawnSync('/usr/bin/stat', ['-f', '-c', '%T', dir], { encoding: 'utf8' })
    if (type.status === 0 && type.stdout.trim() === 'btrfs') return dir
  }
  return null
}

test('on btrfs, a +C image is copied +C and shares its blocks', t => {
  const under = btrfsDir()
  if (!under) return t.skip('no btrfs folder (set OMAWIN_TEST_BTRFS)')
  const lsattr = file => spawnSync('/usr/bin/lsattr', ['-d', file], { encoding: 'utf8' }).stdout.split(' ')[0]
  const { env, home } = box(t, { written: 0, under })
  // +C only takes on an empty file: remake data.img inside a +C folder.
  const image = path.join(env.WINDOWS_DIR, 'data.img')
  fs.rmSync(image)
  assert.equal(spawnSync('/usr/bin/chattr', ['+C', env.WINDOWS_DIR]).status, 0)
  fs.writeFileSync(image, Buffer.alloc(4 * MIB, 7))
  fs.truncateSync(image, 64 * 1024 ** 3)
  assert.match(lsattr(image), /C/)
  const real = { ...env }
  delete real.REFLINK
  assert.equal(fields(helper('backup.sh', ['plan'], real).out).reflink, '1')
  const result = helper('backup.sh', ['run'], real)
  assert.equal(result.status, 0, result.err)
  const copy = path.join(home, '.windows.bak-2026-10-04/windows/data.img')
  assert.match(lsattr(copy), /C/)
  const extents = spawnSync('/usr/bin/filefrag', ['-v', copy], { encoding: 'utf8' }).stdout
  assert.match(extents, /shared/, 'the copy shares the original\'s blocks')
})
