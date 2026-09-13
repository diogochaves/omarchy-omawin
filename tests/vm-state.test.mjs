import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { dataImage, fixtures, vmState } from './helpers.mjs'

const CID = '3fff20be218cd2379160eb8acf4144ac6aafd0dacbf17f78f2e4f020466084b9'
// tests/fixtures/generate.sh: btime 1789179802 + field 22 (632100 ticks at
// USER_HZ 100) = 6321 s in.
const STARTED = 1789186123

test('a running VM reports every field', () => {
  assert.equal(
    vmState('running', { WEB_CODE: '401' }),
    'installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=' + CID +
      ' started=' + STARTED + ' disk=64G login=chaves'
  )
})

test('a paused VM differs only in cgroup.freeze', () => {
  assert.equal(
    vmState('paused', { WEB_CODE: '401' }),
    'installed=1 docker=active pid=1360395 frozen=1 cores=4 ram=16G web=401 cid=' + CID +
      ' started=' + STARTED + ' disk=64G login=chaves'
  )
})

test('installed but stopped leaves every process field empty', () => {
  // disk and login are not process fields: they are read off the user's own
  // data.img and credentials file, which are there whether the VM runs or not.
  assert.equal(
    vmState('stopped'),
    'installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started= disk=64G login=chaves'
  )
})

test('a missing credentials file is not-installed, VM running or not', () => {
  assert.equal(
    vmState('not-installed'),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started= disk= login='
  )
})

test('a missing compose file is not-installed too', () => {
  assert.equal(
    vmState('running', { COMPOSE_FILE: '/nonexistent/docker-compose.yml' }),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started= disk= login='
  )
})

test('not-installed skips both probes even when they would answer', () => {
  // The fixture's procfs holds a live VM: installed=0 must short-circuit the
  // /proc scan and the curl alike, which is what the sampler does on the real
  // box when ~/.config/windows/credentials is missing.
  assert.equal(
    vmState('not-installed', { WEB_CODE: '401' }),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started= disk= login='
  )
})

test('the docker state is passed through verbatim', () => {
  assert.equal(
    vmState('stopped', { DOCKER_STATE: 'inactive' }),
    'installed=1 docker=inactive pid= frozen= cores= ram= web=000 cid= started= disk=64G login=chaves'
  )
})

test('the decoys are all present in the fixture, and all ignored', () => {
  const proc = path.join(fixtures, 'running/proc')
  // comm "windows" + qemu argv, but not in a container.
  assert.equal(fs.readFileSync(path.join(proc, '1001/comm'), 'utf8').trim(), 'windows')
  assert.equal(fs.readFileSync(path.join(proc, '1001/cgroup'), 'utf8').includes('docker-'), false)
  // comm "windows" inside a docker scope, but argv[0] is not qemu.
  assert.equal(fs.readFileSync(path.join(proc, '1002/cgroup'), 'utf8').includes('docker-'), true)
  assert.equal(
    fs.readFileSync(path.join(proc, '1002/cmdline'), 'utf8').startsWith('qemu-system-x86_64'),
    false
  )
  // Another QEMU on the box, whose comm is the binary name.
  assert.equal(fs.readFileSync(path.join(proc, '1003/comm'), 'utf8').trim(), 'qemu-system-x86_64')

  // They sort before the real pid, so only the three guards together can make
  // the sampler pick the right one...
  assert.equal(vmState('running').includes('pid=1360395'), true)
  // ...and the stopped fixture is these same three decoys with the VM gone,
  // where any missing guard would report a pid.
  assert.deepEqual(fs.readdirSync(path.join(fixtures, 'stopped/proc')).sort(),
    ['1001', '1002', '1003', 'stat'])
  assert.equal(vmState('stopped').includes('pid= '), true)
})

test('started survives a comm with spaces and a bracket in it', () => {
  // The kernel does not escape comm, so "field 22" can only be counted from
  // the last ')' — a process renamed to something like "win (x) dows" would
  // shift every field for a naive split.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-proc-'))
  fs.cpSync(path.join(fixtures, 'running/proc'), dir, { recursive: true })
  const statPath = path.join(dir, '1360395/stat')
  fs.writeFileSync(statPath,
    fs.readFileSync(statPath, 'utf8').replace('(windows)', '(win (x) dows)'))
  try {
    assert.equal(
      vmState('running', { PROC_ROOT: dir, WEB_CODE: '401' }),
      'installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=' + CID +
        ' started=' + STARTED + ' disk=64G login=chaves'
    )
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('no btime line means no started, not a bogus epoch', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-proc-'))
  fs.cpSync(path.join(fixtures, 'running/proc'), dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'stat'), 'cpu  0 0 0 0\n')
  try {
    // Empty, and empty in the middle of the line now that disk and login
    // follow it.
    assert.match(vmState('running', { PROC_ROOT: dir, WEB_CODE: '401' }), / started= /)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('disk is the apparent size of data.img, in whole GiB, or nothing', () => {
  // 68719476736 bytes is what the fixture's sparse image reports on this box.
  assert.equal(fs.statSync(dataImage('stopped')).size, 68719476736)
  assert.match(vmState('stopped'), / disk=64G /)

  // Missing, empty, and not a whole number of GiB: all three blank the field
  // rather than printing a size the writer would refuse.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-img-'))
  try {
    assert.match(vmState('stopped', { DATA_IMAGE: path.join(dir, 'gone.img') }), / disk= /)

    const odd = path.join(dir, 'odd.img')
    fs.writeFileSync(odd, '')
    fs.truncateSync(odd, 64 * 1024 ** 3 + 512)
    assert.match(vmState('stopped', { DATA_IMAGE: odd }), / disk= /)

    const small = path.join(dir, 'small.img')
    fs.writeFileSync(small, '')
    assert.match(vmState('stopped', { DATA_IMAGE: small }), / disk= /)

    const big = path.join(dir, 'big.img')
    fs.writeFileSync(big, '')
    fs.truncateSync(big, 96 * 1024 ** 3)
    assert.match(vmState('stopped', { DATA_IMAGE: big }), / disk=96G /)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('login is the USERNAME line and only ever that', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-creds-'))
  const file = path.join(dir, 'credentials')
  const line = extra => vmState('stopped', { CREDENTIALS_FILE: file, ...extra })
  try {
    // The password is on the line above and contains an = and a $, which the
    // sampler must neither split on nor print.
    fs.writeFileSync(file, 'PASSWORD=a=b$c\nUSERNAME=alice\n')
    assert.match(line(), / login=alice$/)
    assert.equal(line().includes('a=b'), false)
    assert.equal(line().includes('PASSWORD'), false)

    // No USERNAME line, and a name the VM writer would refuse: both blank.
    fs.writeFileSync(file, 'PASSWORD=secret\n')
    assert.match(line(), / login=$/)
    fs.writeFileSync(file, 'USERNAME=not a user name\nPASSWORD=secret\n')
    assert.match(line(), / login=$/)
    fs.writeFileSync(file, 'USERNAME=' + 'x'.repeat(21) + '\nPASSWORD=secret\n')
    assert.match(line(), / login=$/)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
