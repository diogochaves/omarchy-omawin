.pragma library

// The state machine of chaves.omawin, as pure functions of their arguments.
// No I/O, no timers, no QML: Service.qml feeds in the last line of
// helpers/vm-state.sh, the last helpers/rdp-probe.sh result and the pending
// user action, and gets back a state name plus everything the panel prints.
//
// Loadable both as a QML resource (import "lib/State.js" as State) and under
// node --test, which strips the .pragma line and evaluates the rest in a vm
// context; hence ES5, var functions and no exports.

// Transients expire into failure: the launcher waits at most 2 min for
// "windows started successfully", and stop_grace_period is 2 min.
var START_TIMEOUT = 150000
var STOP_TIMEOUT = 130000

var KEYS = ["installed", "docker", "pid", "frozen", "cores", "ram", "web", "cid"]

function emptySample() {
  return {
    installed: false, docker: "", pid: 0, frozen: false,
    cores: 0, ram: "", web: 0, cid: ""
  }
}

// One "k=v k=v …" line from helpers/vm-state.sh. Anything unparseable (an
// empty line, a helper that died, a stray warning) yields the not-installed
// shape with an empty docker state, which classifies as "not-installed".
function parseSample(line) {
  var sample = emptySample()
  if (typeof line !== "string") return sample
  var fields = {}
  var parts = line.replace(/^\s+|\s+$/g, "").split(/\s+/)
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq > 0) fields[parts[i].substring(0, eq)] = parts[i].substring(eq + 1)
  }
  for (var k = 0; k < KEYS.length; k++) {
    if (!fields.hasOwnProperty(KEYS[k])) return sample
  }
  sample.installed = fields.installed === "1"
  sample.docker = fields.docker
  sample.pid = toInt(fields.pid)
  sample.frozen = fields.frozen === "1"
  sample.cores = toInt(fields.cores)
  sample.ram = fields.ram
  sample.web = toInt(fields.web)
  sample.cid = fields.cid
  return sample
}

function toInt(text) {
  var value = parseInt(text, 10)
  return isFinite(value) && value > 0 ? value : 0
}

// The state the sampler alone says we are in, with no pending action layered
// on top. Precedence: not-installed > paused > (QEMU present → booting/ready
// by the RDP probe) > stopped. `probe` is {ok: bool, at: ms} or null.
function sampled(sample, probe) {
  if (!sample || !sample.installed) return "not-installed"
  if (!sample.pid) return "stopped"
  if (sample.frozen) return "paused"
  return probe && probe.ok ? "ready" : "booting"
}

// The state to paint. `desired` is the transient the user asked for,
// {action: "start"|"stop"|null, since: ms, failed: string}, the same idea as
// jkwuc89's _desired; `now` is Date.now().
//
// A transient ends the moment the sampler contradicts it (start + QEMU up →
// booting/ready/paused, stop + no QEMU → stopped) and expires into "failed"
// if the sampler never catches up. `desired.failed` is sticky: it keeps the
// state at "failed" until the caller clears it. "not-installed" outranks
// everything — with no compose there is nothing to start, stop or fail.
function classify(sample, probe, desired, now) {
  var base = sampled(sample, probe)
  if (base === "not-installed") return base
  var action = desired && desired.action ? desired.action : null
  var since = desired && isFinite(desired.since) ? desired.since : 0
  var elapsed = (isFinite(now) ? now : 0) - since
  var state = base
  if (action === "start" && !sample.pid)
    state = elapsed >= START_TIMEOUT ? "failed" : "starting"
  else if (action === "stop" && sample.pid)
    state = elapsed >= STOP_TIMEOUT ? "failed" : "stopping"
  if (desired && desired.failed) state = "failed"
  return state
}

var LABELS = {
  "not-installed": "NOT INSTALLED",
  "stopped": "STOPPED",
  "starting": "STARTING",
  "booting": "BOOTING",
  "ready": "READY",
  "paused": "PAUSED",
  "stopping": "STOPPING",
  "failed": "FAILED"
}

function label(state) {
  return LABELS.hasOwnProperty(state) ? LABELS[state] : "UNKNOWN"
}

// The cores·RAM pill. Live values win; `cached` is the {cores, ram} the
// Service wrote down the last time the VM ran, so a stopped VM still shows
// its shape. "" when neither is known.
function detail(sample, cached) {
  var cores = sample && sample.cores ? sample.cores : 0
  var ram = sample && sample.ram ? sample.ram : ""
  if (!cores || !ram) {
    cores = cached && cached.cores ? Number(cached.cores) : 0
    ram = cached && cached.ram ? String(cached.ram) : ""
  }
  if (!cores || !ram) return ""
  return cores + (cores === 1 ? " core · " : " cores · ") + ram
}

// Which buttons the panel enables. "failed" shows the buttons of the state
// underneath it so the user can retry, so pass `base` (from sampled()) with
// it; without one it falls back to "stopped".
function allowedActions(state, sample, base) {
  if (state === "failed")
    return allowedActions(base && base !== "failed" ? base : "stopped", sample)
  var web = sample && sample.web === 401
  var installed = state !== "not-installed"
  return {
    start: state === "stopped",
    connect: state === "ready",
    stop: state === "booting" || state === "ready" || state === "paused",
    pause: state === "ready",
    resume: state === "paused",
    web: state === "booting" || state === "ready" || (state === "starting" && web),
    shared: installed,
    install: state === "not-installed"
  }
}

// How often to send an X.224 Connection Request: fast while the guest boots,
// a slow keepalive once it is up (to notice a guest reboot), never otherwise.
function probeInterval(state) {
  if (state === "booting") return 3000
  if (state === "ready") return 30000
  return 0
}

// How often to run helpers/vm-state.sh. With no VM installed the only thing
// that can change is whether two files exist.
function sampleInterval(state) {
  return state === "not-installed" ? 30000 : 5000
}

// The bar tooltip. A dead docker.service is worth calling out: every action
// fails fast without it and the reason is not otherwise visible.
function tooltip(state, sample, desired) {
  var text = "Windows VM · " + label(state)
  if (sample && sample.docker && sample.docker !== "active")
    text += " · docker.service is " + sample.docker
  if (state === "failed" && desired && desired.failed)
    text += " · " + desired.failed
  return text
}
