import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import test from 'node:test'
import { root } from './helpers.mjs'

// Runs the real helpers/launch-result.sh with UNIT_PROPS and UNIT_JOURNAL
// standing in for systemctl and journalctl. props: null is a collected unit.
function launchResult(journal, props = null) {
  const env = { ...process.env, UNIT_JOURNAL: journal.join('\n') }
  env.UNIT_PROPS = props ? props.join('\n') : 'not-found\ninactive\nsuccess\n0'
  return execFileSync('/bin/bash', ['helpers/launch-result.sh'], {
    cwd: root, encoding: 'utf8', env
  }).replace(/\n$/, '')
}

const STARTED = 'Started [systemd-run] /usr/bin/omarchy-windows-vm launch -k.'
const CLOSED = [
  'RDP session closed. Windows VM is still running.',
  'To stop it: omarchy-windows-vm stop',
  'omawin-launch.service: Consumed 601ms CPU time over 604ms wall clock time, 87.7M memory peak.'
]

// The lines xfreerdp 3 logged on a restored VM whose stored login was not the
// Windows account's, trimmed to the ones around the error.
function refused(code) {
  return [
    STARTED,
    'Starting Windows VM (this may prompt for authorization)...',
    '[08:51:55:483] [755246:000b8630] [WARN][com.freerdp.crypto] - [tls_verify_certificate]: [DANGER] Certificate not checked, /cert:ignore in use.',
    '[08:51:55:483] [755246:000b8630] [ERROR][com.winpr.sspi.Kerberos] - [kerberos_AcquireCredentialsHandleA]: krb5_parse_name (Configuration file does not specify default realm [-1765328160])',
    `[08:51:55:484] [755246:000b8630] [ERROR][com.freerdp.core] - [nla_recv_pdu]: ${code} [0x00020014]`,
    '[08:51:55:484] [755246:000b8630] [ERROR][com.freerdp.core.rdp] - [rdp_recv_callback_int][0x5c7c18d47280]: CONNECTION_STATE_NLA - nla_recv_pdu() fail',
    ...CLOSED
  ]
}

const REJECTED = 'Windows rejected the username or password. Check Login, and Update login if you changed it in Windows.'

test('a refused login fails the launch although the launcher exited 0', () => {
  assert.equal(launchResult(refused('ERRCONNECT_LOGON_FAILURE')), REJECTED)
  assert.equal(launchResult(refused('ERRCONNECT_WRONG_PASSWORD')), REJECTED)
})

test('a refused login is reported while the exited unit is still loaded', () => {
  const props = ['loaded', 'inactive', 'success', '0']
  assert.equal(launchResult(refused('ERRCONNECT_LOGON_FAILURE'), props), REJECTED)
})

test('a locked-out or expired account says so', () => {
  assert.match(launchResult(refused('ERRCONNECT_ACCOUNT_LOCKED_OUT')), /^Windows locked the account/)
  assert.match(launchResult(refused('ERRCONNECT_PASSWORD_EXPIRED')), /^Windows wants a new password/)
  assert.match(launchResult(refused('ERRCONNECT_PASSWORD_MUST_CHANGE')), /^Windows wants a new password/)
})

test('a session that ran and closed is still ok', () => {
  assert.equal(launchResult([STARTED, 'Starting Windows VM (this may prompt for authorization)...', ...CLOSED]), 'ok')
})

test('a refused login from an earlier run does not outlive a clean one', () => {
  const journal = [...refused('ERRCONNECT_LOGON_FAILURE'), STARTED, ...CLOSED]
  assert.equal(launchResult(journal), 'ok')
})

test('a running unit is ok whatever its journal says', () => {
  const props = ['loaded', 'active', 'success', '0']
  assert.equal(launchResult(refused('ERRCONNECT_LOGON_FAILURE'), props), 'ok')
})

test('other errors in a clean run are not failures', () => {
  const journal = refused('ERRCONNECT_CONNECT_TRANSPORT_FAILED')
  assert.equal(launchResult(journal), 'ok')
})

test('a non-zero exit still reports the launcher\'s last words', () => {
  const journal = [
    STARTED,
    'omarchy-windows-vm: refusing an unsafe VM mount anchor',
    'omawin-launch.service: Main process exited, code=exited, status=1/FAILURE',
    'omawin-launch.service: Failed with result \'exit-code\'.'
  ]
  assert.equal(launchResult(journal), 'omarchy-windows-vm: refusing an unsafe VM mount anchor')
})
