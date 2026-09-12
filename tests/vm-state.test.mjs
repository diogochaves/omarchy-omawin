import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fixtures, vmState } from './helpers.mjs'

const CID = '3fff20be218cd2379160eb8acf4144ac6aafd0dacbf17f78f2e4f020466084b9'

test('a running VM reports every field', () => {
  assert.equal(
    vmState('running', { WEB_CODE: '401' }),
    'installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=' + CID
  )
})

test('a paused VM differs only in cgroup.freeze', () => {
  assert.equal(
    vmState('paused', { WEB_CODE: '401' }),
    'installed=1 docker=active pid=1360395 frozen=1 cores=4 ram=16G web=401 cid=' + CID
  )
})

test('installed but stopped leaves every process field empty', () => {
  assert.equal(
    vmState('stopped'),
    'installed=1 docker=active pid= frozen= cores= ram= web=000 cid='
  )
})

test('a missing credentials file is not-installed, VM running or not', () => {
  assert.equal(
    vmState('not-installed'),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid='
  )
})

test('a missing compose file is not-installed too', () => {
  assert.equal(
    vmState('running', { COMPOSE_FILE: '/nonexistent/docker-compose.yml' }),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid='
  )
})

test('not-installed skips both probes even when they would answer', () => {
  // The fixture's procfs holds a live VM: installed=0 must short-circuit the
  // /proc scan and the curl alike, which is what the sampler does on the real
  // box when ~/.config/windows/credentials is missing.
  assert.equal(
    vmState('not-installed', { WEB_CODE: '401' }),
    'installed=0 docker=active pid= frozen= cores= ram= web=000 cid='
  )
})

test('the docker state is passed through verbatim', () => {
  assert.equal(
    vmState('stopped', { DOCKER_STATE: 'inactive' }),
    'installed=1 docker=inactive pid= frozen= cores= ram= web=000 cid='
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
    ['1001', '1002', '1003'])
  assert.equal(vmState('stopped').includes('pid= '), true)
})
