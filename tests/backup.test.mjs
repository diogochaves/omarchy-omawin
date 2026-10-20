import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper, root } from './helpers.mjs'

// helpers/backup.sh against a throwaway home: a ~/.windows with a sparse
// data.img that has a little written to it, and a credentials file.
// FREE_BYTES and REFLINK stand in for df and the filesystem type; HOME is
// the throwaway home, and BACKUP_ROOT pins the backup there unless a test
// is about where it goes.
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
  // An installed VM: Omarchy's compose is there. The drives' folders are
  // not searched, and the record of places is the throwaway home's.
  const compose = path.join(home, 'docker-compose.yml')
  fs.writeFileSync(compose, 'services: {}\n')
  return {
    home,
    env: {
      HOME: home, WINDOWS_DIR: windows, CREDENTIALS_FILE: creds, BACKUP_ROOT: home,
      TODAY: '2026-10-04', FREE_BYTES: String(500 * 1024 ** 3), REFLINK: '0',
      COMPOSE_FILE: compose, LEGACY_COMPOSE_FILE: path.join(home, 'no-legacy.yml'),
      BACKUP_SEARCH: '', BACKUP_PLACES: path.join(home, 'state', 'backup-places'),
      SHARED_DIR: path.join(home, 'Windows'), APPS_DIR: path.join(home, 'apps')
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
  assert.match(result.out, /\ndone=\/.*\/\.windows\.bak-2026-10-04$/)
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
  assert.match(result.out, /\ndone=\/.*\/\.windows\.bak-2026-10-04$/)
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

// Where it goes (#31): beside the VM's real folder, so on its drive. A
// ~/.windows that points at another folder gets its backup there.
test('a backup goes beside the folder ~/.windows points to', t => {
  const { env, home } = box(t, { written: 2 })
  const drive = path.join(home, 'data')
  fs.mkdirSync(drive)
  fs.renameSync(env.WINDOWS_DIR, path.join(drive, 'windows'))
  fs.symlinkSync(path.join(drive, 'windows'), env.WINDOWS_DIR)
  fs.mkdirSync(path.join(home, '.windows.bak-2026-10-01'))
  const beside = { ...env }
  delete beside.BACKUP_ROOT
  const plan = helper('backup.sh', ['plan'], beside)
  assert.equal(plan.status, 0, plan.err)
  const f = fields(plan.out)
  assert.equal(f.where, drive)
  assert.equal(f.target, 'windows.bak-2026-10-04')
  assert.equal(f.same, '1')
  // A backup an earlier version left in $HOME still counts as the last one.
  assert.match(f.last, /^[0-9]+$/)
  assert.match(plan.out, / where=[^ ]+$/, 'where comes last')
  const result = helper('backup.sh', ['run'], beside)
  assert.equal(result.status, 0, result.err)
  assert.match(result.out, new RegExp(`\ndone=${drive}/windows\\.bak-2026-10-04$`))
  assert.equal(fs.statSync(path.join(drive, 'windows.bak-2026-10-04/windows/data.img')).size, 64 * 1024 ** 3)
  assert.equal(fs.existsSync(path.join(drive, 'windows.bak-2026-10-04/credentials')), true)
})

test('a folder beside it that is not writable falls back to $HOME', t => {
  const { env, home } = box(t)
  const drive = path.join(home, 'locked')
  fs.mkdirSync(drive)
  fs.renameSync(env.WINDOWS_DIR, path.join(drive, 'windows'))
  fs.symlinkSync(path.join(drive, 'windows'), env.WINDOWS_DIR)
  const beside = { ...env }
  delete beside.BACKUP_ROOT
  fs.chmodSync(drive, 0o555)
  let f
  try {
    f = fields(helper('backup.sh', ['plan'], beside).out)
  } finally {
    fs.chmodSync(drive, 0o755)
  }
  assert.equal(f.where, home)
  assert.equal(f.target, '.windows.bak-2026-10-04')
})

// Another drive: same=0, which the face says, since that copy also outlives
// the drive the VM is on. Needs two filesystems: the tmpdir and a btrfs one.
test('a backup on another filesystem says same=0', t => {
  const under = btrfsDir()
  if (!under) return t.skip('no second filesystem (set OMAWIN_TEST_BTRFS)')
  const { env } = box(t)
  if (spawnSync('/usr/bin/stat', ['-f', '-c', '%T', os.tmpdir()], { encoding: 'utf8' }).stdout.trim() === 'btrfs')
    return t.skip('the tmpdir is btrfs too')
  const other = fs.mkdtempSync(path.join(under, 'omawin-backup-root-'))
  t.after(() => fs.rmSync(other, { recursive: true, force: true }))
  const f = fields(helper('backup.sh', ['plan'], { ...env, BACKUP_ROOT: other }).out)
  assert.equal(f.same, '0')
  assert.equal(f.where, other)
})

// The list (#23): every backup beside the VM's folder and in $HOME, newest
// first, with what deleting it frees. Half-made and look-alike folders are
// not backups.
const lines = out => out.split('\n').filter(Boolean).map(line => {
  const at = line.indexOf(' path=')
  return { ...fields(line.slice(0, at)), path: line.slice(at + 6) }
})

function fakeBackup(dir, when) {
  fs.mkdirSync(path.join(dir, 'windows'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'windows', 'data.img'), Buffer.alloc(64 * 1024, 1))
  fs.utimesSync(dir, when, when)
}

test('list shows every backup, newest first, with its own size', t => {
  const { env, home } = box(t)
  const drive = path.join(home, 'data')
  fs.mkdirSync(drive)
  fs.renameSync(env.WINDOWS_DIR, path.join(drive, 'windows'))
  fs.symlinkSync(path.join(drive, 'windows'), env.WINDOWS_DIR)
  fakeBackup(path.join(drive, 'windows.bak-2026-10-20'), 1792500000)
  fakeBackup(path.join(home, '.windows.bak-2026-10-04'), 1791100000)
  fakeBackup(path.join(drive, 'windows.bak-2026-10-12'), 1791800000)
  fakeBackup(path.join(drive, 'windows.bak-2026-10-21.partial'), 1792600000)
  fs.mkdirSync(path.join(drive, 'windows.bak-2026-10-22'))
  fs.symlinkSync(path.join(drive, 'windows.bak-2026-10-20'), path.join(home, '.windows.bak-2026-10-23'))
  const beside = { ...env }
  delete beside.BACKUP_ROOT
  const result = helper('backup.sh', ['list'], beside)
  assert.equal(result.status, 0, result.err)
  const list = lines(result.out)
  assert.deepEqual(list.map(b => path.basename(b.path)),
    ['windows.bak-2026-10-20', 'windows.bak-2026-10-12', '.windows.bak-2026-10-04'])
  assert.deepEqual(list.map(b => b.when), ['1792500000', '1791800000', '1791100000'])
  for (const b of list) {
    assert.match(b.own, /^[0-9]+$/)
    assert.match(b.measured, /^(btrfs|du)$/)
    assert.equal(b.same, '1')
  }
})

test('list with no backups is empty, and lists them with no VM folder too', t => {
  const { env, home } = box(t)
  const empty = helper('backup.sh', ['list'], env)
  assert.equal(empty.status, 0, empty.err)
  assert.equal(empty.out, '')
  fakeBackup(path.join(home, '.windows.bak-2026-10-04'), 1791100000)
  fs.rmSync(env.WINDOWS_DIR, { recursive: true })
  const gone = helper('backup.sh', ['list'], env)
  assert.equal(gone.status, 0, gone.err)
  assert.deepEqual(lines(gone.out).map(b => [path.basename(b.path), b.same]), [['.windows.bak-2026-10-04', '0']])
})

// Remove VM deletes the ~/.windows link that led to a backup on another
// drive: the folder it went to is remembered, and the drives' tops are
// looked in, so it is still listed.
test('list finds backups where ~/.windows used to point, and on a drive', t => {
  const { env, home } = box(t)
  const drive = path.join(home, 'data')
  fs.mkdirSync(drive)
  fs.renameSync(env.WINDOWS_DIR, path.join(drive, 'windows'))
  fs.symlinkSync(path.join(drive, 'windows'), env.WINDOWS_DIR)
  const beside = { ...env }
  delete beside.BACKUP_ROOT
  assert.equal(helper('backup.sh', ['run', '--cores', '4', '--ram', '8G'], beside).status, 0)
  // As Remove leaves it: the link gone, the folder it pointed to emptied.
  fs.rmSync(env.WINDOWS_DIR)
  fs.rmSync(path.join(drive, 'windows'), { recursive: true })
  fs.mkdirSync(path.join(drive, 'windows'))
  const result = helper('backup.sh', ['list'], beside)
  assert.equal(result.status, 0, result.err)
  const [b] = lines(result.out)
  assert.equal(b.path, path.join(drive, 'windows.bak-2026-10-04'))
  assert.deepEqual([b.disk, b.cores, b.ram], ['64G', '4', '8G'])
  // With no record, a backup at the top of a drive is found all the same.
  fs.rmSync(env.BACKUP_PLACES)
  const other = path.join(home, 'usb')
  fakeBackup(path.join(other, 'windows.bak-2026-10-01'), 1790900000)
  const searched = helper('backup.sh', ['list'], { ...beside, BACKUP_SEARCH: `${drive} ${other}` })
  assert.deepEqual(lines(searched.out).map(b => [path.basename(b.path), b.cores]),
    [['windows.bak-2026-10-04', '4'], ['windows.bak-2026-10-01', '']])
})

test('on btrfs, list says a fresh backup holds next to nothing of its own', t => {
  const under = btrfsDir()
  if (!under) return t.skip('no btrfs folder (set OMAWIN_TEST_BTRFS)')
  const { env, home } = box(t, { written: 0, under })
  const image = path.join(env.WINDOWS_DIR, 'data.img')
  fs.rmSync(image)
  assert.equal(spawnSync('/usr/bin/chattr', ['+C', env.WINDOWS_DIR]).status, 0)
  fs.writeFileSync(image, Buffer.alloc(4 * MIB, 7))
  const real = { ...env }
  delete real.REFLINK
  assert.equal(helper('backup.sh', ['run'], real).status, 0)
  spawnSync('/usr/bin/sync', ['-f', home])
  const [b] = lines(helper('backup.sh', ['list'], real).out)
  assert.equal(b.measured, 'btrfs')
  assert.ok(Number(b.own) < MIB, `own=${b.own}: the copy shares the image's blocks`)
})

// Delete (#23) takes only a path `list` names: nothing else goes, whatever
// it is called.
test('delete removes a listed backup and refuses anything else', t => {
  const { env, home } = box(t)
  fakeBackup(path.join(home, '.windows.bak-2026-10-04'), 1791100000)
  fakeBackup(path.join(home, '.windows.bak-2026-10-05.partial'), 1791100000)
  fs.mkdirSync(path.join(home, '.windows.bak-2026-10-06'))
  fs.symlinkSync(env.WINDOWS_DIR, path.join(home, '.windows.bak-2026-10-07'))
  const refuse = (target, why) => {
    const result = helper('backup.sh', ['delete', target], env)
    assert.equal(result.status, 2, `${target}: ${result.out}`)
    assert.match(result.err, why)
  }
  refuse(env.WINDOWS_DIR, /not a backup/)
  refuse(path.join(home, '.windows.bak-2026-10-05.partial'), /not a backup/)
  refuse(path.join(home, '.windows.bak-2026-10-06'), /not a backup/)
  refuse(path.join(home, '.windows.bak-2026-10-07'), /not a backup/)
  refuse(path.join(home, '.windows.bak-2026-10-04/'), /not a backup/)
  refuse('/etc', /not a backup/)
  refuse('', /usage/)
  assert.ok(fs.existsSync(path.join(env.WINDOWS_DIR, 'data.img')), 'the VM is untouched')

  const target = path.join(home, '.windows.bak-2026-10-04')
  const result = helper('backup.sh', ['delete', target], env)
  assert.equal(result.status, 0, result.err)
  assert.equal(result.out, `deleted=${target}`)
  assert.equal(fs.existsSync(target), false)
  assert.ok(fs.existsSync(path.join(home, '.windows.bak-2026-10-05.partial')))
  assert.ok(fs.existsSync(path.join(env.WINDOWS_DIR, 'data.img')))
})

// Restore (#23): a safety backup first, the backup's disk and login back,
// and the compose rewritten only when the login or the disk differs. The
// pkexec step is the dry run here.
function restoreBox(t) {
  const made = box(t, { written: 2 })
  const env = { ...made.env, VM_RUNNING: '0', RESTORE_DRY_RUN: '1', TZ_NAME: 'UTC' }
  assert.equal(helper('backup.sh', ['run'], env).status, 0)
  const backup = path.join(made.home, '.windows.bak-2026-10-04')
  // Windows moves on after the backup: other bytes, another login.
  const image = path.join(env.WINDOWS_DIR, 'data.img')
  const fd = fs.openSync(image, 'r+')
  fs.writeSync(fd, Buffer.alloc(MIB, 9), 0, MIB, 0)
  fs.closeSync(fd)
  fs.writeFileSync(env.CREDENTIALS_FILE, 'USERNAME=other\nPASSWORD=changed\n', { mode: 0o600 })
  return { env, home: made.home, backup, image }
}

const firstByte = file => {
  const fd = fs.openSync(file, 'r')
  const b = Buffer.alloc(1)
  fs.readSync(fd, b, 0, 1, 0)
  fs.closeSync(fd)
  return b[0]
}

test('restore puts the backup back and keeps the VM it replaced', t => {
  const { env, home, backup, image } = restoreBox(t)
  const args = ['restore', backup, '--cores', '3', '--ram', '4G', '--disk', '64G']
  // Omarchy pins the VM's folder by device and inode: it has to stay.
  const pin = fs.statSync(env.WINDOWS_DIR)
  const result = helper('backup.sh', args, env)
  assert.equal(result.status, 0, result.err)
  const steps = result.out.split('\n').filter(l => l.startsWith('step=')).map(l => l.slice(5))
  assert.deepEqual(steps, ['safety', 'copy', 'swap', 'compose'])
  assert.match(result.out, /dry run: compose not rewritten \(RAM=4G CORES=3 DISK=64G USERNAME=chaves\)/)
  assert.match(result.out, /\ncomposed=3 4G 64G\n/)
  const after = fs.statSync(env.WINDOWS_DIR)
  assert.deepEqual([after.dev, after.ino, after.mode & 0o777], [pin.dev, pin.ino, pin.mode & 0o777])
  assert.match(result.out, new RegExp(`\\nrestored=${backup}$`))
  // The backup's bytes are the VM's again, and its login.
  assert.equal(firstByte(image), 7)
  assert.equal(fs.statSync(image).size, 64 * 1024 ** 3)
  assert.equal(fs.readFileSync(env.CREDENTIALS_FILE, 'utf8'), 'USERNAME=chaves\nPASSWORD=secret\n')
  assert.equal(fs.statSync(env.CREDENTIALS_FILE).mode & 0o777, 0o600)
  // The VM it replaced is a backup now, with its own login.
  const safety = path.join(home, '.windows.bak-2026-10-04-2')
  assert.match(result.out, new RegExp(`\\ndone=${safety}\\n`))
  assert.equal(firstByte(path.join(safety, 'windows/data.img')), 9)
  assert.equal(fs.readFileSync(path.join(safety, 'credentials'), 'utf8'), 'USERNAME=other\nPASSWORD=changed\n')
  // The backup itself stays, and nothing half-made is left.
  assert.equal(firstByte(path.join(backup, 'windows/data.img')), 7)
  assert.deepEqual(fs.readdirSync(home).filter(n => /restoring|replaced|partial|errors/.test(n)), [])
})

test('restore of an identical login and disk does not touch the compose', t => {
  const { env, backup } = restoreBox(t)
  fs.writeFileSync(env.CREDENTIALS_FILE, 'USERNAME=chaves\nPASSWORD=secret\n', { mode: 0o600 })
  const result = helper('backup.sh', ['restore', backup, '--disk', '64G'], env)
  assert.equal(result.status, 0, result.err)
  assert.doesNotMatch(result.out, /step=compose|dry run/)
})

test('restore refuses a running VM, a path that is not a backup, and an unknown shape', t => {
  const { env, home, backup, image } = restoreBox(t)
  const args = ['restore', backup, '--cores', '3', '--ram', '4G', '--disk', '64G']
  const running = helper('backup.sh', args, { ...env, VM_RUNNING: '1' })
  assert.equal(running.status, 2)
  assert.match(running.err, /stop the VM first/)
  const stranger = helper('backup.sh', ['restore', env.WINDOWS_DIR, '--disk', '64G'], env)
  assert.equal(stranger.status, 2)
  assert.match(stranger.err, /not a backup/)
  const shapeless = helper('backup.sh', ['restore', backup, '--disk', '64G'], env)
  assert.equal(shapeless.status, 2)
  assert.match(shapeless.err, /core count is not known/)
  // None of them changed the VM or made a safety backup.
  assert.equal(firstByte(image), 9)
  assert.equal(fs.readFileSync(env.CREDENTIALS_FILE, 'utf8'), 'USERNAME=other\nPASSWORD=changed\n')
  assert.deepEqual(fs.readdirSync(home).filter(n => n.startsWith('.windows.bak')), ['.windows.bak-2026-10-04'])
})

test('restore without room for the safety backup changes nothing', t => {
  const { env, home, backup, image } = restoreBox(t)
  const tight = { ...env, FREE_BYTES: String(1024 ** 3) }
  const result = helper('backup.sh', ['restore', backup, '--cores', '3', '--ram', '4G', '--disk', '64G'], tight)
  assert.equal(result.status, 2)
  assert.match(result.err, /not enough room for the safety backup/)
  assert.equal(firstByte(image), 9)
  assert.deepEqual(fs.readdirSync(home).filter(n => n.startsWith('.windows.bak')), ['.windows.bak-2026-10-04'])
})

test('on btrfs, a restored +C disk shares its blocks with the backup', t => {
  const under = btrfsDir()
  if (!under) return t.skip('no btrfs folder (set OMAWIN_TEST_BTRFS)')
  const lsattr = file => spawnSync('/usr/bin/lsattr', ['-d', file], { encoding: 'utf8' }).stdout.split(' ')[0]
  const { env, home } = box(t, { written: 0, under })
  const image = path.join(env.WINDOWS_DIR, 'data.img')
  fs.rmSync(image)
  assert.equal(spawnSync('/usr/bin/chattr', ['+C', env.WINDOWS_DIR]).status, 0)
  fs.writeFileSync(image, Buffer.alloc(4 * MIB, 7))
  fs.truncateSync(image, 64 * 1024 ** 3)
  const real = { ...env, VM_RUNNING: '0', RESTORE_DRY_RUN: '1', TZ_NAME: 'UTC' }
  delete real.REFLINK
  assert.equal(helper('backup.sh', ['run'], real).status, 0)
  const backup = path.join(home, '.windows.bak-2026-10-04')
  const result = helper('backup.sh', ['restore', backup, '--disk', '64G'], real)
  assert.equal(result.status, 0, result.err)
  assert.match(lsattr(path.join(env.WINDOWS_DIR, 'data.img')), /C/)
  const extents = spawnSync('/usr/bin/filefrag', ['-v', path.join(env.WINDOWS_DIR, 'data.img')], { encoding: 'utf8' }).stdout
  assert.match(extents, /shared/, 'the restored disk shares the backup\'s blocks')
})

// A dismissed dialog comes after the swap: the VM's own files go back in,
// and nothing has changed but the safety backup.
test('restore with the dialog dismissed puts the VM back as it was', t => {
  const { env, home, backup, image } = restoreBox(t)
  const pin = fs.statSync(env.WINDOWS_DIR)
  const result = helper('backup.sh', ['restore', backup, '--cores', '3', '--ram', '4G', '--disk', '64G'],
    { ...env, RESTORE_DRY_RUN: 'dismiss' })
  assert.equal(result.status, 1)
  assert.match(result.err, /Request dismissed/)
  assert.doesNotMatch(result.out, /restored=|composed=/)
  assert.equal(firstByte(image), 9)
  assert.equal(fs.readFileSync(env.CREDENTIALS_FILE, 'utf8'), 'USERNAME=other\nPASSWORD=changed\n')
  assert.equal(fs.statSync(env.WINDOWS_DIR).ino, pin.ino)
  assert.deepEqual(fs.readdirSync(env.WINDOWS_DIR).sort(), ['data.img', 'windows.ver'])
  assert.deepEqual(fs.readdirSync(home).filter(n => /restoring|replaced|partial|errors/.test(n)), [])
  assert.ok(fs.existsSync(path.join(home, '.windows.bak-2026-10-04-2')), 'the safety backup stays')
})

// Restore after Remove VM: no compose, no login, the VM's folder empty or
// gone. The backup goes back where it was made, the compose is written (the
// dry run here) and the login and launcher entry come back.
function removedBox(t, { onDrive = false } = {}) {
  const made = box(t, { written: 2 })
  const env = { ...made.env, RESTORE_DRY_RUN: '1', TZ_NAME: 'UTC' }
  delete env.BACKUP_ROOT
  let folder = env.WINDOWS_DIR
  if (onDrive) {
    folder = path.join(made.home, 'data', 'windows')
    fs.mkdirSync(path.dirname(folder))
    fs.renameSync(env.WINDOWS_DIR, folder)
    fs.symlinkSync(folder, env.WINDOWS_DIR)
  }
  assert.equal(helper('backup.sh', ['run', '--cores', '4', '--ram', '8G'], env).status, 0)
  const backup = path.join(path.dirname(folder), `${path.basename(folder)}.bak-2026-10-04`)
  // As Omarchy's remove leaves it: the compose and login gone, the VM's
  // folder emptied, ~/.windows deleted (an empty one may come back).
  fs.rmSync(env.COMPOSE_FILE)
  fs.rmSync(env.CREDENTIALS_FILE)
  fs.rmSync(env.WINDOWS_DIR, { recursive: true })
  if (onDrive) {
    fs.rmSync(folder, { recursive: true })
    fs.mkdirSync(folder)
    fs.mkdirSync(env.WINDOWS_DIR, { mode: 0o700 })
  }
  return { env, home: made.home, backup, folder }
}

const steps = out => out.split('\n').filter(l => l.startsWith('step=')).map(l => l.slice(5))

test('after Remove VM, restore brings the VM back where it was', t => {
  const { env, home, backup } = removedBox(t)
  const result = helper('backup.sh', ['restore', backup, '--cores', '4', '--ram', '8G', '--disk', '—'], env)
  assert.equal(result.status, 0, result.err)
  assert.deepEqual(steps(result.out), ['copy', 'swap', 'compose'])
  assert.match(result.out, /dry run: compose not written \(RAM=8G CORES=4 DISK=64G USERNAME=chaves\)/)
  assert.match(result.out, /\ncomposed=4 8G 64G\n/)
  assert.match(result.out, new RegExp(`\\nrestored=${backup}$`))
  assert.doesNotMatch(result.out, /done=/, 'no safety backup: there was nothing to save')
  const image = path.join(env.WINDOWS_DIR, 'data.img')
  assert.equal(firstByte(image), 7)
  assert.equal(fs.statSync(image).size, 64 * 1024 ** 3)
  assert.equal(fs.statSync(env.WINDOWS_DIR).mode & 0o777, 0o700)
  assert.equal(fs.readFileSync(env.CREDENTIALS_FILE, 'utf8'), 'USERNAME=chaves\nPASSWORD=secret\n')
  assert.equal(fs.statSync(env.CREDENTIALS_FILE).mode & 0o777, 0o600)
  assert.match(fs.readFileSync(path.join(env.APPS_DIR, 'windows-vm.desktop'), 'utf8'), /Exec=uwsm app -- omarchy-windows-vm launch/)
  assert.ok(fs.statSync(env.SHARED_DIR).isDirectory(), 'the Shared folder is back')
  assert.equal(firstByte(path.join(backup, 'windows/data.img')), 7, 'the backup stays')
  assert.deepEqual(fs.readdirSync(home).filter(n => /restoring|replaced|partial|errors/.test(n)), [])
})

test('after Remove VM, a VM that lived on another drive goes back there, linked', t => {
  const { env, backup, folder } = removedBox(t, { onDrive: true })
  const result = helper('backup.sh', ['restore', backup, '--cores', '2', '--ram', '4G'], env)
  assert.equal(result.status, 0, result.err)
  assert.equal(fs.readlinkSync(env.WINDOWS_DIR), folder)
  assert.equal(firstByte(path.join(folder, 'data.img')), 7)
  assert.deepEqual(fs.readdirSync(path.dirname(folder)).filter(n => /restoring/.test(n)), [])
})

test('after Remove VM, a dismissed dialog takes the restore away again', t => {
  const { env, backup, folder } = removedBox(t, { onDrive: true })
  const result = helper('backup.sh', ['restore', backup, '--cores', '2', '--ram', '4G'],
    { ...env, RESTORE_DRY_RUN: 'dismiss' })
  assert.equal(result.status, 1)
  assert.match(result.err, /Request dismissed/)
  assert.doesNotMatch(result.out, /restored=|composed=/)
  // As it was: an empty ~/.windows, an empty folder on the drive, no login.
  assert.ok(!fs.lstatSync(env.WINDOWS_DIR).isSymbolicLink())
  assert.deepEqual(fs.readdirSync(env.WINDOWS_DIR), [])
  assert.deepEqual(fs.readdirSync(folder), [])
  assert.equal(fs.existsSync(env.CREDENTIALS_FILE), false)
  assert.equal(fs.existsSync(path.join(env.APPS_DIR, 'windows-vm.desktop')), false)
  assert.equal(firstByte(path.join(backup, 'windows/data.img')), 7)
})

test('after Remove VM, restore refuses a folder in use, a backup with no login and no shape', t => {
  const { env, backup } = removedBox(t)
  const args = ['restore', backup, '--cores', '2', '--ram', '4G']
  const shapeless = helper('backup.sh', ['restore', backup], env)
  assert.equal(shapeless.status, 2)
  assert.match(shapeless.err, /needs --cores/)
  fs.mkdirSync(env.WINDOWS_DIR)
  fs.writeFileSync(path.join(env.WINDOWS_DIR, 'notes.txt'), 'mine\n')
  const busy = helper('backup.sh', args, env)
  assert.equal(busy.status, 2)
  assert.match(busy.err, /already holds files/)
  assert.equal(fs.readFileSync(path.join(env.WINDOWS_DIR, 'notes.txt'), 'utf8'), 'mine\n')
  fs.rmSync(env.WINDOWS_DIR, { recursive: true })
  fs.rmSync(path.join(backup, 'credentials'))
  const loginless = helper('backup.sh', args, env)
  assert.equal(loginless.status, 2)
  assert.match(loginless.err, /has no login/)
  assert.equal(fs.existsSync(env.WINDOWS_DIR), false)
})
