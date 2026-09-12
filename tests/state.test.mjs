import assert from 'node:assert/strict'
import test from 'node:test'
import { load } from './helpers.mjs'

const State = load('lib/State.js')

const CID = '3fff20be218cd2379160eb8acf4144ac6aafd0dacbf17f78f2e4f020466084b9'
const RUNNING = 'installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=' + CID
const PAUSED = RUNNING.replace('frozen=0', 'frozen=1')
const STOPPED = 'installed=1 docker=active pid= frozen= cores= ram= web=000 cid='
const ABSENT = 'installed=0 docker=active pid= frozen= cores= ram= web=000 cid='

const NONE = { action: null, since: 0, failed: '' }
const OK = { ok: true, at: 1000 }
const NO = { ok: false, at: 1000 }

test('parseSample reads a running line', () => {
  assert.deepEqual(State.parseSample(RUNNING), {
    installed: true, docker: 'active', pid: 1360395, frozen: false,
    cores: 4, ram: '16G', web: 401, cid: CID
  })
})

test('parseSample reads a stopped line, empty values and all', () => {
  assert.deepEqual(State.parseSample(STOPPED), {
    installed: true, docker: 'active', pid: 0, frozen: false,
    cores: 0, ram: '', web: 0, cid: ''
  })
})

test('parseSample reads a not-installed line', () => {
  assert.deepEqual(State.parseSample(ABSENT), {
    installed: false, docker: 'active', pid: 0, frozen: false,
    cores: 0, ram: '', web: 0, cid: ''
  })
})

test('parseSample survives garbage, a truncated line and no line at all', () => {
  const empty = {
    installed: false, docker: '', pid: 0, frozen: false,
    cores: 0, ram: '', web: 0, cid: ''
  }
  for (const bad of ['', '\n', 'bash: line 12: /proc: no such file', 'installed=1 docker=active',
    undefined, null, 42]) {
    assert.deepEqual(State.parseSample(bad), empty, JSON.stringify(bad))
  }
})

test('parseSample tolerates surrounding whitespace', () => {
  assert.equal(State.parseSample('  ' + RUNNING + ' \n').pid, 1360395)
})

test('sampled is the state with no action pending', () => {
  assert.equal(State.sampled(State.parseSample(ABSENT), null), 'not-installed')
  assert.equal(State.sampled(State.parseSample(STOPPED), null), 'stopped')
  assert.equal(State.sampled(State.parseSample(RUNNING), null), 'booting')
  assert.equal(State.sampled(State.parseSample(RUNNING), NO), 'booting')
  assert.equal(State.sampled(State.parseSample(RUNNING), OK), 'ready')
  // Frozen outranks the probe: a paused VM keeps answering nothing.
  assert.equal(State.sampled(State.parseSample(PAUSED), OK), 'paused')
  assert.equal(State.sampled(null, null), 'not-installed')
})

test('classify without a pending action is just the sample', () => {
  const at = 1e6
  assert.equal(State.classify(State.parseSample(ABSENT), null, NONE, at), 'not-installed')
  assert.equal(State.classify(State.parseSample(STOPPED), null, NONE, at), 'stopped')
  assert.equal(State.classify(State.parseSample(RUNNING), NO, NONE, at), 'booting')
  assert.equal(State.classify(State.parseSample(RUNNING), OK, NONE, at), 'ready')
  assert.equal(State.classify(State.parseSample(PAUSED), OK, NONE, at), 'paused')
  // A null desired is the same as no action.
  assert.equal(State.classify(State.parseSample(RUNNING), OK, null, at), 'ready')
})

test('start is a transient until QEMU shows up', () => {
  const start = { action: 'start', since: 1000, failed: '' }
  const stopped = State.parseSample(STOPPED)
  assert.equal(State.classify(stopped, null, start, 1000), 'starting')
  assert.equal(State.classify(stopped, null, start, 1000 + 149000), 'starting')
})

test('start expires into failed after 150 s with no QEMU', () => {
  const start = { action: 'start', since: 1000, failed: '' }
  assert.equal(State.classify(State.parseSample(STOPPED), null, start, 1000 + 150000), 'failed')
  assert.equal(State.classify(State.parseSample(STOPPED), null, start, 1000 + 300000), 'failed')
})

test('the sampler contradicting start ends the transient at once', () => {
  const start = { action: 'start', since: 1000, failed: '' }
  assert.equal(State.classify(State.parseSample(RUNNING), NO, start, 2000), 'booting')
  assert.equal(State.classify(State.parseSample(RUNNING), OK, start, 2000), 'ready')
  assert.equal(State.classify(State.parseSample(PAUSED), NO, start, 2000), 'paused')
  // Even past the deadline: QEMU is there, the start worked.
  assert.equal(State.classify(State.parseSample(RUNNING), OK, start, 1e9), 'ready')
})

test('stop is a transient while QEMU is still there', () => {
  const stop = { action: 'stop', since: 1000, failed: '' }
  const running = State.parseSample(RUNNING)
  assert.equal(State.classify(running, OK, stop, 1000), 'stopping')
  assert.equal(State.classify(running, OK, stop, 1000 + 129000), 'stopping')
  assert.equal(State.classify(State.parseSample(PAUSED), null, stop, 1000), 'stopping')
})

test('stop expires into failed after 130 s with QEMU still alive', () => {
  const stop = { action: 'stop', since: 1000, failed: '' }
  assert.equal(State.classify(State.parseSample(RUNNING), OK, stop, 1000 + 130000), 'failed')
})

test('the sampler contradicting stop ends the transient at once', () => {
  const stop = { action: 'stop', since: 1000, failed: '' }
  assert.equal(State.classify(State.parseSample(STOPPED), null, stop, 2000), 'stopped')
  assert.equal(State.classify(State.parseSample(STOPPED), null, stop, 1e9), 'stopped')
})

test('failed is sticky until the caller clears it', () => {
  const failed = { action: null, since: 1000, failed: 'Failed to start Windows VM' }
  assert.equal(State.classify(State.parseSample(STOPPED), null, failed, 2000), 'failed')
  assert.equal(State.classify(State.parseSample(RUNNING), OK, failed, 2000), 'failed')
  assert.equal(State.classify(State.parseSample(RUNNING), OK, NONE, 2000), 'ready')
})

test('not-installed outranks every transient and a sticky failure', () => {
  const absent = State.parseSample(ABSENT)
  for (const desired of [
    { action: 'start', since: 0, failed: '' },
    { action: 'stop', since: 0, failed: '' },
    { action: null, since: 0, failed: 'boom' }
  ]) {
    assert.equal(State.classify(absent, OK, desired, 1e9), 'not-installed')
  }
})

test('label covers every state', () => {
  assert.deepEqual(
    ['not-installed', 'stopped', 'starting', 'booting', 'ready', 'paused', 'stopping', 'failed']
      .map(State.label),
    ['NOT INSTALLED', 'STOPPED', 'STARTING', 'BOOTING', 'READY', 'PAUSED', 'STOPPING', 'FAILED']
  )
  assert.equal(State.label('nonsense'), 'UNKNOWN')
})

test('detail prefers the live sample, falls back to the cache, else empty', () => {
  const running = State.parseSample(RUNNING)
  const stopped = State.parseSample(STOPPED)
  assert.equal(State.detail(running, null), '4 cores · 16G')
  assert.equal(State.detail(running, { cores: 8, ram: '32G' }), '4 cores · 16G')
  assert.equal(State.detail(stopped, { cores: 4, ram: '16G' }), '4 cores · 16G')
  assert.equal(State.detail(stopped, { cores: 1, ram: '4G' }), '1 core · 4G')
  assert.equal(State.detail(stopped, null), '')
  assert.equal(State.detail(stopped, { cores: 4 }), '')
  assert.equal(State.detail(null, null), '')
})

// The panel's buttons, state by state. Everything not listed is disabled.
const EXPECTED = {
  'not-installed': ['install'],
  'stopped': ['start', 'shared'],
  'starting': ['shared'],
  'booting': ['stop', 'web', 'shared'],
  'ready': ['connect', 'stop', 'pause', 'web', 'shared'],
  'paused': ['stop', 'resume', 'shared'],
  'stopping': ['shared']
}

test('allowedActions matches the per-state table', () => {
  // The sample that really goes with each state: no QEMU yet while starting.
  const samples = {
    'not-installed': State.parseSample(ABSENT),
    'stopped': State.parseSample(STOPPED),
    'starting': State.parseSample(STOPPED),
    'stopping': State.parseSample(RUNNING),
    'paused': State.parseSample(PAUSED)
  }
  for (const state of Object.keys(EXPECTED)) {
    const sample = samples[state] || State.parseSample(RUNNING)
    const actions = State.allowedActions(state, sample)
    const on = Object.keys(actions).filter(key => actions[key]).sort()
    assert.deepEqual(on, EXPECTED[state].slice().sort(), state)
  }
})

test('Web viewer appears in starting only once 8006 answers 401', () => {
  assert.equal(State.allowedActions('starting', State.parseSample(STOPPED)).web, false)
  const answering = State.parseSample(STOPPED.replace('web=000', 'web=401'))
  assert.equal(State.allowedActions('starting', answering).web, true)
  // Any other code is not the viewer being up.
  const half = State.parseSample(STOPPED.replace('web=000', 'web=502'))
  assert.equal(State.allowedActions('starting', half).web, false)
})

test('failed shows the buttons of the state underneath it', () => {
  const running = State.parseSample(RUNNING)
  assert.deepEqual(
    State.allowedActions('failed', running, 'ready'),
    State.allowedActions('ready', running)
  )
  assert.deepEqual(
    State.allowedActions('failed', running, State.sampled(running, null)),
    State.allowedActions('booting', running)
  )
  // No base, or a nonsensical one, falls back to stopped so Start is offered.
  assert.equal(State.allowedActions('failed', running).start, true)
  assert.equal(State.allowedActions('failed', running, 'failed').start, true)
})

test('probeInterval only probes while it can learn something', () => {
  assert.equal(State.probeInterval('booting'), 3000)
  assert.equal(State.probeInterval('ready'), 30000)
  for (const state of ['not-installed', 'stopped', 'starting', 'paused', 'stopping', 'failed'])
    assert.equal(State.probeInterval(state), 0, state)
})

test('sampleInterval backs off only when nothing is installed', () => {
  assert.equal(State.sampleInterval('not-installed'), 30000)
  for (const state of ['stopped', 'starting', 'booting', 'ready', 'paused', 'stopping', 'failed'])
    assert.equal(State.sampleInterval(state), 5000, state)
})

test('tooltip names the state, a dead docker and the failure', () => {
  const running = State.parseSample(RUNNING)
  assert.equal(State.tooltip('ready', running, NONE), 'Windows VM · READY')
  assert.equal(
    State.tooltip('stopped', State.parseSample(STOPPED.replace('docker=active', 'docker=inactive')), NONE),
    'Windows VM · STOPPED · docker.service is inactive'
  )
  assert.equal(
    State.tooltip('failed', running, { action: null, since: 0, failed: 'Failed to start Windows VM' }),
    'Windows VM · FAILED · Failed to start Windows VM'
  )
  // An unparseable sample has no docker state to report, so it says nothing.
  assert.equal(State.tooltip('not-installed', State.parseSample(''), NONE),
    'Windows VM · NOT INSTALLED')
  assert.equal(State.tooltip('stopped', null, null), 'Windows VM · STOPPED')
})
