import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper, root } from './helpers.mjs'

// Runs the real ./setup against a throwaway directory standing in for
// /etc/polkit-1/rules.d, unprivileged. The hooks are documented in the script's
// header: POLKIT_RULES_DIR moves the target directory, OMAWIN_STATE_DIR moves
// the user-owned copy it leaves for the widget (SETUP_TARGET_HOME derives that
// from a home instead), and SETUP_SKIP_ROOT_CHECK=1 waives the root guard
// (install(1) then also drops its -o root -g root, which a non-root user cannot
// honour). SUDO_USER is blanked so a test never picks up whoever ran
// `node --test` through sudo.
function setup(args, { dir, state, env = {} } = {}) {
  const result = spawnSync(path.join(root, 'setup'), args, {
    cwd: root, encoding: 'utf8', env: {
      ...process.env,
      SUDO_USER: '',
      POLKIT_RULES_DIR: dir,
      ...(state === undefined ? {} : { OMAWIN_STATE_DIR: state }),
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

// A throwaway stand-in for ~/.local/state/omawin, where the copy the widget
// reads is left. Returned without being created: setup has to create it.
function stateDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-state-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return path.join(dir, 'omawin')
}

const RULE = '49-omawin.rules'
const PROBE = '49-omawin-probe.rules'
const PROBE_SRC = '49-omawin-probe.rules.in'
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
  const { status, out } = setup(['polkit', '--yes', '--user', 'alice'], { dir })
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
  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir }).status, 0)
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

test('--probe installs a rule that allows only __priv status on an exact match', t => {
  // (the probe is rendered for a user like the real rule, hence --user)
  const dir = rulesDir(t)
  const { status, out } = setup(['polkit', '--yes', '--probe', '--user', 'alice'], { dir })
  assert.equal(status, 0, out)
  assert.match(out, /__priv status extra/)

  const rule = loadRule(path.join(dir, PROBE))
  const status_ = {
    user: 'alice',
    program: '/usr/bin/omarchy-windows-vm',
    commandLine: '/usr/bin/omarchy-windows-vm __priv status'
  }
  assert.equal(ask(rule, status_), 'yes', 'the one probe command line')
  assert.equal(ask(rule, { ...status_, user: 'bob' }), undefined, 'the probe is per user too')
  assert.equal(ask(rule, { ...status_, commandLine: status_.commandLine + ' extra' }), undefined)
  assert.equal(ask(rule, { ...status_, commandLine: '/usr/bin/omarchy-windows-vm __priv down' }), undefined)
  assert.equal(ask(rule, { ...status_, commandLine: '/usr/bin/omarchy-windows-vm __priv up_wait' }), undefined)
  assert.equal(ask(rule, { ...status_, program: '/usr/share/omarchy/bin/omarchy-windows-vm' }), undefined)
  assert.equal(ask(rule, { ...status_, id: 'org.freedesktop.login1.reboot' }), undefined)
})

test('installing the real rule takes the probe back out', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--yes', '--probe', '--user', 'alice'], { dir }).status, 0)
  const { status, out } = setup(['polkit', '--yes', '--user', 'alice'], { dir })
  assert.equal(status, 0, out)
  assert.match(out, /removed .*49-omawin-probe\.rules/)
  assert.equal(fs.existsSync(path.join(dir, PROBE)), false)
  assert.equal(fs.existsSync(path.join(dir, RULE)), true)
})

test('without --yes and without a terminal nothing is installed', t => {
  const dir = rulesDir(t)
  const { status, out } = setup(['polkit', '--user', 'alice'], { dir })
  assert.notEqual(status, 0)
  assert.match(out, /About to install this file, as root/)
  assert.match(out, /subject\.user !== "alice"/, 'the rendered rule is shown before the refusal')
  assert.match(out, /re-run with --yes/)
  assert.deepEqual(fs.readdirSync(dir), [])
})

test('installing twice is idempotent', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir }).status, 0)
  const first = fs.readFileSync(path.join(dir, RULE), 'utf8')
  const { status } = setup(['polkit', '--yes', '--user', 'alice'], { dir })
  assert.equal(status, 0)
  assert.equal(fs.readFileSync(path.join(dir, RULE), 'utf8'), first)
  assert.deepEqual(fs.readdirSync(dir), [RULE])
})

test('--remove takes both files out, and says so only for what was there', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--yes', '--probe', '--user', 'alice'], { dir }).status, 0)
  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir }).status, 0)
  fs.copyFileSync(path.join(root, 'polkit', PROBE_SRC), path.join(dir, PROBE))

  const { status, out } = setup(['polkit', '--yes', '--remove'], { dir })
  assert.equal(status, 0, out)
  assert.match(out, /removed .*49-omawin\.rules/)
  assert.match(out, /removed .*49-omawin-probe\.rules/)
  assert.deepEqual(fs.readdirSync(dir), [])

  const again = setup(['polkit', '--yes', '--remove'], { dir })
  assert.equal(again.status, 0)
  assert.match(again.out, /nothing to remove/)
})

test('an unusable target user is refused, nothing is written', t => {
  const dir = rulesDir(t)

  const asRoot = setup(['polkit', '--yes', '--user', 'root'], { dir })
  assert.notEqual(asRoot.status, 0)
  assert.match(asRoot.out, /refusing to write a rule for root/)

  const nobody = setup(['polkit', '--yes'], { dir })
  assert.notEqual(nobody.status, 0)
  assert.match(nobody.out, /no target user: pass --user NAME/)

  const nonsense = setup(['polkit', '--yes', '--user', 'Alice Smith'], { dir })
  assert.notEqual(nonsense.status, 0)
  assert.match(nonsense.out, /not a plausible user name/)

  assert.deepEqual(fs.readdirSync(dir), [])
})

test('--status reports the presence of both files and who the rule names', t => {
  const dir = rulesDir(t)

  const empty = setup(['polkit', '--yes', '--status'], { dir })
  assert.equal(empty.status, 0, empty.out)
  assert.match(empty.out, /absent .*49-omawin\.rules/)
  assert.match(empty.out, /absent .*49-omawin-probe\.rules/)

  assert.equal(setup(['polkit', '--yes', '--probe', '--user', 'alice'], { dir }).status, 0)
  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir }).status, 0)
  fs.copyFileSync(path.join(root, 'polkit', PROBE_SRC), path.join(dir, PROBE))

  const both = setup(['polkit', '--yes', '--status'], { dir })
  assert.equal(both.status, 0, both.out)
  assert.match(both.out, /present .*49-omawin\.rules \(user: alice\)/)
  assert.match(both.out, /present .*49-omawin-probe\.rules/)
})

test('SUDO_USER is the default target, and --user wins over it', t => {
  const dir = rulesDir(t)
  assert.equal(setup(['polkit', '--yes'], { dir, env: { SUDO_USER: 'carol' } }).status, 0)
  assert.match(fs.readFileSync(path.join(dir, RULE), 'utf8'),
    /subject\.user !== "carol"/)

  assert.equal(
    setup(['polkit', '--yes', '--user', 'alice'], { dir, env: { SUDO_USER: 'carol' } }).status, 0)
  assert.match(fs.readFileSync(path.join(dir, RULE), 'utf8'),
    /subject\.user !== "alice"/)
})

// --------------------------------------- the copy the widget reads back out

test('installing leaves a user-owned copy of exactly what was installed', t => {
  const dir = rulesDir(t)
  const state = stateDir(t)
  const { status, out } = setup(['polkit', '--yes', '--user', 'alice'], { dir, state })
  assert.equal(status, 0, out)
  assert.match(out, /recorded .*49-omawin\.rules \(a user-owned copy/)

  // /etc/polkit-1/rules.d is root:polkitd 0750, so this copy is the only thing
  // the widget can look at — and it is the installed file, byte for byte, not a
  // second rendering of the template.
  const copy = path.join(state, RULE)
  assert.equal(fs.readFileSync(copy, 'utf8'), fs.readFileSync(path.join(dir, RULE), 'utf8'))
  assert.equal(fs.statSync(copy).mode & 0o777, 0o644)
  assert.match(fs.readFileSync(copy, 'utf8'), /subject\.user !== "alice"/)

  // Its mtime is when it was installed: that is the caption's date.
  assert.ok(Date.now() - fs.statSync(copy).mtimeMs < 60000)

  // Installing again is still idempotent, copy and all.
  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir, state }).status, 0)
  assert.deepEqual(fs.readdirSync(state), [RULE])
})

test('the probe rule is not recorded: it is not the rule the switch is about', t => {
  const dir = rulesDir(t)
  const state = stateDir(t)
  assert.equal(setup(['polkit', '--yes', '--probe', '--user', 'alice'], { dir, state }).status, 0)
  assert.equal(fs.existsSync(path.join(state, RULE)), false)
  assert.equal(fs.existsSync(state), false)
})

test('--remove takes the copy out too, even when the rule itself is gone', t => {
  const dir = rulesDir(t)
  const state = stateDir(t)
  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir, state }).status, 0)

  const removed = setup(['polkit', '--yes', '--remove', '--user', 'alice'], { dir, state })
  assert.equal(removed.status, 0, removed.out)
  assert.match(removed.out, /removed .*49-omawin\.rules \(the widget's copy\)/)
  assert.deepEqual(fs.readdirSync(state), [])

  // A rule taken out by hand leaves the copy behind — the stale record the card
  // warns about — and --remove is what cleans it up.
  fs.writeFileSync(path.join(state, RULE), 'polkit.addRule(function () {});\n')
  const stale = setup(['polkit', '--yes', '--remove', '--user', 'alice'], { dir, state })
  assert.equal(stale.status, 0)
  assert.match(stale.out, /removed .*\(the widget's copy\)/)
  assert.deepEqual(fs.readdirSync(state), [])
})

test('--status reports the copy, and says when it cannot know where it is', t => {
  const dir = rulesDir(t)
  const state = stateDir(t)

  const before = setup(['polkit', '--yes', '--status', '--user', 'alice'], { dir, state })
  assert.equal(before.status, 0, before.out)
  assert.match(before.out, /absent .*49-omawin\.rules — the widget's Settings switch reads as off/)

  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir, state }).status, 0)
  const after = setup(['polkit', '--yes', '--status', '--user', 'alice'], { dir, state })
  assert.match(after.out, /present .*49-omawin\.rules \(user: alice\) — what the widget reads/)

  // No $SUDO_USER, no --user and no hook: there is no home to resolve, and it
  // says so rather than reporting an absence it did not check.
  const blind = setup(['polkit', '--yes', '--status'], { dir, state: '' })
  assert.equal(blind.status, 0, blind.out)
  assert.match(blind.out, /unknown the user-owned copy: no target user/)
})

test('without the hook the copy goes under the target user\'s own home', t => {
  const dir = rulesDir(t)
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-home-'))
  t.after(() => fs.rmSync(home, { recursive: true, force: true }))

  // SETUP_TARGET_HOME stands in for the getent lookup, which a test cannot
  // arrange; the path under it is the one the helper looks in.
  const { status, out } = setup(['polkit', '--yes', '--user', 'alice'],
    { dir, state: '', env: { SETUP_TARGET_HOME: home } })
  assert.equal(status, 0, out)
  const copy = path.join(home, '.local/state/omawin', RULE)
  assert.equal(fs.existsSync(copy), true)
  // The directory it had to create is the user's own private one.
  assert.equal(fs.statSync(path.dirname(copy)).mode & 0o777, 0o700)
})

test('a rule it could not record is still installed, with a warning', t => {
  const dir = rulesDir(t)
  // A state directory that cannot be created: the rule is what matters, and the
  // widget's switch simply reads as off.
  const { status, out } = setup(['polkit', '--yes', '--user', 'alice'],
    { dir, state: '/proc/nonexistent/omawin' })
  assert.equal(status, 0, out)
  assert.equal(fs.existsSync(path.join(dir, RULE)), true)
  assert.doesNotMatch(out, /recorded/)
})

// --------------------------------- what the widget makes of the copy again

test('helpers/rule-state.sh reads that copy, and nothing else', t => {
  const dir = rulesDir(t)
  const state = stateDir(t)
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-home-'))
  t.after(() => fs.rmSync(home, { recursive: true, force: true }))

  const absent = helper('rule-state.sh', [], { OMAWIN_STATE_DIR: state, HOME: home })
  assert.equal(absent.status, 0)
  assert.equal(absent.out, 'present=0 user= since=')

  assert.equal(setup(['polkit', '--yes', '--user', 'alice'], { dir, state }).status, 0)
  const present = helper('rule-state.sh', [], { OMAWIN_STATE_DIR: state, HOME: home })
  assert.equal(present.status, 0)
  assert.match(present.out, /^present=1 user=alice since=[0-9]{10}$/)

  // The fallback: a user whose XDG_STATE_HOME points elsewhere still finds the
  // copy setup wrote under ~/.local/state, because it looks there too.
  const fallback = path.join(home, '.local/state/omawin')
  fs.mkdirSync(fallback, { recursive: true })
  fs.copyFileSync(path.join(state, RULE), path.join(fallback, RULE))
  const moved = helper('rule-state.sh', [],
    { OMAWIN_STATE_DIR: path.join(home, 'elsewhere'), HOME: home })
  assert.match(moved.out, /^present=1 user=alice since=[0-9]{10}$/)
})
