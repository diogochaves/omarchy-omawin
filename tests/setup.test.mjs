import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { root } from './helpers.mjs'

// Runs the real ./setup against a throwaway directory standing in for
// /etc/polkit-1/rules.d, unprivileged. The two hooks are documented in the
// script's header: POLKIT_RULES_DIR moves the target directory and
// SETUP_SKIP_ROOT_CHECK=1 waives the root guard (install(1) then also drops
// its -o root -g root, which a non-root user cannot honour). SUDO_USER is
// blanked so a test never picks up whoever ran `node --test` through sudo.
function setup(args, { dir, env = {} } = {}) {
  const result = spawnSync(path.join(root, 'setup'), args, {
    cwd: root, encoding: 'utf8', env: {
      ...process.env,
      SUDO_USER: '',
      POLKIT_RULES_DIR: dir,
      SETUP_SKIP_ROOT_CHECK: '1',
      ...env
    }
  })
  return { status: result.status, out: result.stdout + result.stderr }
}

function rulesDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-rules-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return dir
}

const RULE = '49-omawin.rules'
const PROBE = '49-omawin-probe.rules'
const EXEC = 'org.freedesktop.policykit.exec'

// The rule is a plain script that calls polkit.addRule once. Evaluate it with
// a stub polkit and hand back the function it registered, so the tests can
// ask the installed file itself what it answers, instead of reading it.
function loadRule(file) {
  let rule
  const polkit = {
    addRule(fn) { rule = fn },
    Result: { YES: 'yes', NO: 'no', AUTH_SELF: 'auth_self' },
    log() {}
  }
  new Function('polkit', fs.readFileSync(file, 'utf8'))(polkit)
  assert.equal(typeof rule, 'function', 'the rule registered no function')
  return rule
}

// One pkexec authorization request, shaped the way polkitd presents it.
function ask(rule, { user, program, commandLine, id = EXEC }) {
  const details = { program, command_line: commandLine, cmdline_short: program }
  return rule({ id, lookup: key => details[key] }, { user })
}

const ALLOWED = [
  ['/usr/bin/omarchy-windows-vm', '/usr/bin/omarchy-windows-vm __priv status'],
  ['/usr/bin/omarchy-windows-vm', '/usr/bin/omarchy-windows-vm __priv up_wait'],
  ['/usr/bin/omarchy-windows-vm', '/usr/bin/omarchy-windows-vm __priv down'],
  ['/usr/bin/docker', '/usr/bin/docker pause omarchy-windows'],
  ['/usr/bin/docker', '/usr/bin/docker unpause omarchy-windows']
]

test('polkit --user alice renders the rule with no placeholder left', t => {
  const dir = rulesDir(t)
  const { status, out } = setup(['polkit', '--user', 'alice'], { dir })
  assert.equal(status, 0, out)

  const file = path.join(dir, RULE)
  const source = fs.readFileSync(file, 'utf8')
  assert.doesNotMatch(source, /@USER@/)
  assert.match(source, /subject\.user !== "alice"/)
  assert.match(out, /installed .*49-omawin\.rules for user alice/)
  // The two commands the plan says to verify with are printed, not implied.
  assert.match(out, /pkexec \/usr\/bin\/omarchy-windows-vm __priv status/)
  assert.match(out, /__priv write_compose <\/dev\/null/)
  assert.equal(fs.statSync(file).mode & 0o777, 0o644)

  // Valid JavaScript on its own, before anything evaluates it.
  const copy = path.join(dir, 'rendered.js')
  fs.copyFileSync(file, copy)
  execFileSync(process.execPath, ['--check', copy])
})

test('the rendered rule says YES to exactly the five command lines', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--user', 'alice'], { dir }).status, 0)
  const rule = loadRule(path.join(dir, RULE))

  for (const [program, commandLine] of ALLOWED) {
    assert.equal(ask(rule, { user: 'alice', program, commandLine }), 'yes',
      commandLine)
  }

  const denied = [
    ['a sixth __priv action stays behind the prompt', {
      user: 'alice',
      program: '/usr/bin/omarchy-windows-vm',
      commandLine: '/usr/bin/omarchy-windows-vm __priv write_compose'
    }],
    ['so does remove', {
      user: 'alice',
      program: '/usr/bin/omarchy-windows-vm',
      commandLine: '/usr/bin/omarchy-windows-vm __priv remove'
    }],
    ['another user gets nothing', {
      user: 'bob',
      program: '/usr/bin/omarchy-windows-vm',
      commandLine: '/usr/bin/omarchy-windows-vm __priv status'
    }],
    ['another action id gets nothing', {
      user: 'alice',
      id: 'org.freedesktop.systemd1.manage-units',
      program: '/usr/bin/omarchy-windows-vm',
      commandLine: '/usr/bin/omarchy-windows-vm __priv status'
    }],
    ['docker is not opened up beyond pause/unpause', {
      user: 'alice',
      program: '/usr/bin/docker',
      commandLine: '/usr/bin/docker run -v /:/host --privileged alpine sh'
    }],
    ['nor is a docker argument prefix enough', {
      user: 'alice',
      program: '/usr/bin/docker',
      commandLine: '/usr/bin/docker pause omarchy-windows --other'
    }]
  ]
  for (const [why, request] of denied) {
    assert.equal(ask(rule, request), undefined, why)
  }
})

test('--probe installs the probe rule and points at the journal', t => {
  const dir = rulesDir(t)
  const { status, out } = setup(['polkit', '--probe'], { dir })
  assert.equal(status, 0, out)

  const source = fs.readFileSync(path.join(dir, PROBE), 'utf8')
  assert.match(source, /polkit\.log\("omawin-probe /)
  assert.doesNotMatch(source, /polkit\.Result/)
  assert.match(out, /journalctl -u polkit .*grep omawin-probe/)

  // It decides nothing, so pkexec keeps prompting for everything.
  const rule = loadRule(path.join(dir, PROBE))
  assert.equal(ask(rule, {
    user: 'alice',
    program: '/usr/bin/omarchy-windows-vm',
    commandLine: '/usr/bin/omarchy-windows-vm __priv status'
  }), undefined)
})

test('installing the real rule takes the probe back out', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--probe'], { dir }).status, 0)
  const { status, out } = setup(['polkit', '--user', 'alice'], { dir })
  assert.equal(status, 0, out)
  assert.match(out, /removed .*49-omawin-probe\.rules/)
  assert.equal(fs.existsSync(path.join(dir, PROBE)), false)
  assert.equal(fs.existsSync(path.join(dir, RULE)), true)
})

test('installing twice is idempotent', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--user', 'alice'], { dir }).status, 0)
  const first = fs.readFileSync(path.join(dir, RULE), 'utf8')
  const { status } = setup(['polkit', '--user', 'alice'], { dir })
  assert.equal(status, 0)
  assert.equal(fs.readFileSync(path.join(dir, RULE), 'utf8'), first)
  assert.deepEqual(fs.readdirSync(dir), [RULE])
})

test('--remove takes both files out, and says so only for what was there', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--probe'], { dir }).status, 0)
  assert.equal(setup(['polkit', '--user', 'alice'], { dir }).status, 0)
  fs.copyFileSync(path.join(root, 'polkit', PROBE), path.join(dir, PROBE))

  const { status, out } = setup(['polkit', '--remove'], { dir })
  assert.equal(status, 0, out)
  assert.match(out, /removed .*49-omawin\.rules/)
  assert.match(out, /removed .*49-omawin-probe\.rules/)
  assert.deepEqual(fs.readdirSync(dir), [])

  const again = setup(['polkit', '--remove'], { dir })
  assert.equal(again.status, 0)
  assert.match(again.out, /nothing to remove/)
})

test('an unusable target user is refused, nothing is written', t => {
  const dir = rulesDir(t)

  const asRoot = setup(['polkit', '--user', 'root'], { dir })
  assert.notEqual(asRoot.status, 0)
  assert.match(asRoot.out, /refusing to write a rule for root/)

  const nobody = setup(['polkit'], { dir })
  assert.notEqual(nobody.status, 0)
  assert.match(nobody.out, /no target user: pass --user NAME/)

  const nonsense = setup(['polkit', '--user', 'Alice Smith'], { dir })
  assert.notEqual(nonsense.status, 0)
  assert.match(nonsense.out, /not a plausible user name/)

  assert.deepEqual(fs.readdirSync(dir), [])
})

test('--status reports the presence of both files and who the rule names', t => {
  const dir = rulesDir(t)

  const empty = setup(['polkit', '--status'], { dir })
  assert.equal(empty.status, 0, empty.out)
  assert.match(empty.out, /absent .*49-omawin\.rules/)
  assert.match(empty.out, /absent .*49-omawin-probe\.rules/)

  assert.equal(setup(['polkit', '--probe'], { dir }).status, 0)
  assert.equal(setup(['polkit', '--user', 'alice'], { dir }).status, 0)
  fs.copyFileSync(path.join(root, 'polkit', PROBE), path.join(dir, PROBE))

  const both = setup(['polkit', '--status'], { dir })
  assert.equal(both.status, 0, both.out)
  assert.match(both.out, /present .*49-omawin\.rules \(user: alice\)/)
  assert.match(both.out, /present .*49-omawin-probe\.rules/)
})

test('SUDO_USER is the default target, and --user wins over it', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit'], { dir, env: { SUDO_USER: 'carol' } }).status, 0)
  assert.match(fs.readFileSync(path.join(dir, RULE), 'utf8'),
    /subject\.user !== "carol"/)

  assert.equal(
    setup(['polkit', '--user', 'alice'], { dir, env: { SUDO_USER: 'carol' } }).status, 0)
  assert.match(fs.readFileSync(path.join(dir, RULE), 'utf8'),
    /subject\.user !== "alice"/)
})
