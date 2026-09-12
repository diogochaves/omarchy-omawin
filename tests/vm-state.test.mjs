import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fixtures, vmState } from './helpers.mjs'

const CID = '3fff20be218cd2379160eb8acf4144ac6aafd0dacbf17f78f2e4f020466084b9'
// tests/fixtures/generate.sh: btime 1789179802 + field 22 (632100 ticks at
// USER_HZ 100) = 6321 s in.
const STARTED = 1789186123

test('a running VM reports every field', () => {
  assert.equal(
    vmState('running', { WEB_CODE: '401' }),
    'installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=' + CID +
      ' started=' + STARTED
  )
})

test('a paused VM differs only in cgroup.freeze', () => {
  assert.equal(
    vmState('paused', { WEB_CODE: '401' }),
    'installed=1 docker=active pid=1360395 frozen=1 cores=4 ram=16G web=401 cid=' + CID +
      ' started=' + STARTED
  )
})

test('installed but stopped leaves every process field empty', () => {
  assert.equal(
    vmState('stopped'),
    'installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started='
  )
})

test('a missing credentials file is not-installed, VM running or not', () => {
  assert.equal(
    vmState('not-installed'),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started='
  )
})

test('a missing compose file is not-installed too', () => {
  assert.equal(
    vmState('running', { COMPOSE_FILE: '/nonexistent/docker-compose.yml' }),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started='
  )
})

test('not-installed skips both probes even when they would answer', () => {
  // The fixture's procfs holds a live VM: installed=0 must short-circuit the
  // /proc scan and the curl alike, which is what the sampler does on the real
  // box when ~/.config/windows/credentials is missing.
  assert.equal(
    vmState('not-installed', { WEB_CODE: '401' }),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started='
  )
})

test('the docker state is passed through verbatim', () => {
  assert.equal(
    vmState('stopped', { DOCKER_STATE: 'inactive' }),
    'installed=1 docker=inactive pid= frozen= cores= ram= web=000 cid= started='
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
        ' started=' + STARTED
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
    assert.equal(vmState('running', { PROC_ROOT: dir, WEB_CODE: '401' }).includes('started='), true)
    assert.equal(vmState('running', { PROC_ROOT: dir, WEB_CODE: '401' }).endsWith('started='), true)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
