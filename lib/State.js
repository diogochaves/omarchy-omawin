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

// Every key a line must carry to be believed at all. `disk` and `login`, added
// in 0.2.0, are deliberately NOT in here: a line from an older helper still
// parses, it just comes back without those two readings.
var KEYS = ["installed", "docker", "pid", "frozen", "cores", "ram", "web", "cid", "started"]

// What each printed field may look like. The sampler only ever prints these
// shapes; a line that does not fit (a stray warning, a mocked line, a helper
// from another version) loses the field rather than putting it on the card.
var RAM_SHAPE = /^[0-9]{1,6}[KMGTkmgt]?$/
var CID_SHAPE = /^[0-9a-f]{12,64}$/
var DOCKER_SHAPE = /^[a-z-]{1,32}$/
// The guest disk as the writer spells it, NNNNG, and the login as its
// valid_username accepts it. Both also gate what Tune may send back.
var DISK_SHAPE = /^[0-9]{1,4}G$/
var LOGIN_SHAPE = /^[A-Za-z0-9_-]{1,20}$/
var MAX_CORES = 1024

function emptySample() {
  return {
    installed: false, docker: "", pid: 0, frozen: false,
    cores: 0, ram: "", web: 0, cid: "", started: 0, disk: "", login: ""
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
  sample.docker = DOCKER_SHAPE.test(fields.docker) ? fields.docker : ""
  sample.pid = toInt(fields.pid)
  sample.frozen = fields.frozen === "1"
  sample.cores = toInt(fields.cores) <= MAX_CORES ? toInt(fields.cores) : 0
  sample.ram = RAM_SHAPE.test(fields.ram) ? fields.ram : ""
  sample.web = toInt(fields.web)
  sample.cid = CID_SHAPE.test(fields.cid) ? fields.cid : ""
  // Epoch seconds, from /proc/<pid>/stat + btime. 0 when there is no pid.
  sample.started = toInt(fields.started)
  // The two readings that do not need the VM to be running: the apparent size
  // of data.img and the USERNAME line of the credentials file. Optional, so a
  // helper from before 0.2.0 blanks them instead of blanking the whole line.
  // `|| ""` before the test: an absent key is `undefined`, and RegExp.test
  // stringifies it — "undefined" is nine letters and would pass LOGIN_SHAPE.
  sample.disk = DISK_SHAPE.test(fields.disk || "") ? fields.disk : ""
  sample.login = LOGIN_SHAPE.test(fields.login || "") ? fields.login : ""
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
// {action: "start"|"stop"|null, since: ms, failed: string}; `now` is
// Date.now().
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

// What the failed card says. A failure some helper reported is quoted as it
// is; a transient that ran out of time has no helper to report it, so the
// machine says why the card is red itself. "" whenever nothing has failed.
function failure(sample, desired, now) {
  if (desired && desired.failed) return String(desired.failed)
  // Whether it timed out is classify's call, so the two cannot disagree;
  // with no sticky failure, "failed" can only be a transient that ran out.
  if (classify(sample, null, desired, now) !== "failed") return ""
  if (desired.action === "start")
    return "The VM did not start within " + span(START_TIMEOUT)
      + ". If an authorisation dialog is still open, answer it; otherwise press Start to try again."
  return "Windows did not shut down within " + span(STOP_TIMEOUT)
    + ". It may still be closing; if it stays up, press Stop again."
}

// "2 min 30 s", "2 min", "45 s", for the timeouts above.
function span(ms) {
  var seconds = Math.round(ms / 1000)
  var minutes = Math.floor(seconds / 60)
  var rest = seconds % 60
  if (!minutes) return rest + " s"
  return minutes + " min" + (rest ? " " + rest + " s" : "")
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

// "4 cores · 16G · 64G" — the pill, and the third term only when the disk is
// known (a sampler from before 0.2.0, or no data.img yet).
function shape(cores, ram, disk) {
  if (!cores || !ram) return ""
  var text = cores + (cores === 1 ? " core · " : " cores · ") + ram
  return disk ? text + " · " + disk : text
}

// The shape the next start will use, once Tune has written one and before the
// VM has run with it: {cores, ram, disk} off the cache, or null.
function pendingShape(cached) {
  var pending = cached && cached.pending ? cached.pending : null
  if (!pending) return null
  var cores = Number(pending.cores)
  if (!(cores > 0) || !RAM_SHAPE.test(String(pending.ram))) return null
  return {
    cores: cores,
    ram: String(pending.ram),
    disk: DISK_SHAPE.test(String(pending.disk)) ? String(pending.disk) : ""
  }
}

// True while a pending shape is what the card should be showing: the VM is not
// running, so the write has not been consumed yet.
function showsPending(sample, cached) {
  return !(sample && sample.pid) && !!pendingShape(cached)
}

// The cores·RAM·disk pill. A pending shape wins on a VM that is off (it is
// what the next start will use), then the live sample, then `cached` — the
// shape the Service wrote down the last time the VM ran, so a stopped VM
// still shows its own. "" when neither cores nor RAM are known.
function detail(sample, cached) {
  var pending = showsPending(sample, cached) ? pendingShape(cached) : null
  if (pending) return shape(pending.cores, pending.ram, pending.disk)
  var cores = sample && sample.cores ? sample.cores : 0
  var ram = sample && sample.ram ? sample.ram : ""
  if (!cores || !ram) {
    cores = cached && cached.cores ? Number(cached.cores) : 0
    ram = cached && cached.ram ? String(cached.ram) : ""
  }
  // The disk is readable whether or not the VM runs, so the live reading wins
  // and the cache only fills in for a helper that did not report one.
  var disk = sample && sample.disk ? sample.disk
    : (cached && cached.disk ? String(cached.disk) : "")
  return shape(cores, ram, disk)
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
    // Tune rewrites the compose, which is only read at the next
    // `docker compose up`: offering it on a running VM would promise a change
    // that silently waits for a restart, so it lives on the stopped card only.
    tune: state === "stopped",
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

// The bar tooltip, the mockup's "Windows VM · ready · 4 cores · 16G ·
// up 1h 12m" (with this widget's uppercase status label). A dead
// docker.service is worth calling out: every action fails fast without it and
// the reason is not otherwise visible. A failure replaces the shape and the
// uptime rather than trailing them — "Windows VM · FAILED · <message>" is the
// whole point of that tooltip, and the mockup shows nothing else on it.
//
// `cached` and `now` are optional: without them the tooltip is what phases
// 1-3 printed, minus nothing.
function tooltip(state, sample, desired, cached, now) {
  var text = "Windows VM · " + label(state)
  var why = state === "failed" ? failure(sample, desired, now) : ""
  if (!why) {
    var pill = detail(sample, cached)
    // A shape that has been saved but not started yet is labelled as such:
    // "next start 6 cores · 16G · 96G" is not what the VM last ran with.
    if (pill) text += " · " + (showsPending(sample, cached) ? "next start " + pill : pill)
    // No clock passed in means no uptime to print.
    if (sample && sample.pid && sample.started && isFinite(now)) {
      var up = uptime(sample.started, now)
      if (up) text += " · up " + up
    }
  }
  if (sample && sample.docker && sample.docker !== "active")
    text += " · docker.service is " + sample.docker
  if (why) text += " · " + why
  return text
}

// ------------------------------------------------------------- the readouts
// Two clocks meet here and they are deliberately different units: `started`
// comes out of /proc in epoch SECONDS, `now` and the cache's `lastSeen` are
// Date.now() MILLISECONDS.

// How long this QEMU has been up: "1h 12m", "42m", "3d 4h", "0m" while it is
// still counting its first minute, "" when the sampler could not work it out
// (no pid, no btime, a helper too old to print `started`).
function uptime(started, now) {
  if (!started || !isFinite(started)) return ""
  var seconds = Math.floor((isFinite(now) ? now : 0) / 1000) - started
  if (!(seconds > 0)) seconds = 0
  var minutes = Math.floor(seconds / 60)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days >= 1) return days + "d " + (hours % 24) + "h"
  if (hours >= 1) return hours + "h " + (minutes % 60) + "m"
  return minutes + "m"
}

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// The stopped card's "Last run": the clock time when it was today ("09:15"),
// the weekday with it inside the last week ("Thu 09:15"), the date beyond
// that ("12 Sep"). "—" when the VM has never run under this widget. Written
// out by hand rather than with toLocaleString, which in QML follows the
// system locale and in node follows ICU — the two would not agree.
function lastRun(cached, now) {
  var at = cached && isFinite(cached.lastSeen) ? Number(cached.lastSeen) : 0
  if (!at) return "—"
  var then = new Date(at)
  var today = new Date(isFinite(now) ? now : 0)
  var clock = pad2(then.getHours()) + ":" + pad2(then.getMinutes())
  if (then.getFullYear() === today.getFullYear()
    && then.getMonth() === today.getMonth()
    && then.getDate() === today.getDate()) return clock
  if (today.getTime() - at < 7 * 24 * 3600 * 1000 && today.getTime() >= at)
    return DAY_NAMES[then.getDay()] + " " + clock
  return then.getDate() + " " + MONTH_NAMES[then.getMonth()]
}

function pad2(value) {
  return (value < 10 ? "0" : "") + value
}

// "12 Sep 2026": the Settings caption's "Installed for X on <date>", from the
// mtime of the rule copy `setup` left behind. Written out by hand for the same
// reason lastRun is — toLocaleString follows the system locale in QML and ICU
// in node, and these two have to agree.
function dateText(at) {
  if (!at || !isFinite(at)) return ""
  var day = new Date(Number(at))
  return day.getDate() + " " + MONTH_NAMES[day.getMonth()] + " " + day.getFullYear()
}

// A disk that grew between the last run and this one: {from, to, dismissed}
// off the cache, or null. dockur makes data.img bigger at the start, but
// Windows leaves C: at its old size and the new space unallocated, so the
// running card says so once, until it is dismissed or the VM stops.
function grewShape(value) {
  if (!value || typeof value !== "object") return null
  var from = String(value.from), to = String(value.to)
  if (!DISK_SHAPE.test(from) || !DISK_SHAPE.test(to)) return null
  if (!(parseInt(to, 10) > parseInt(from, 10))) return null
  var grew = { from: from, to: to }
  if (value.dismissed === true) grew.dismissed = true
  return grew
}

// The running card's banner after a grow, or "". Only while QEMU runs: a
// stopped card has nothing to extend.
function grewNote(sample, cached) {
  var grew = sample && sample.pid && cached ? grewShape(cached.grew) : null
  if (!grew || grew.dismissed) return ""
  return "The disk grew from " + grew.from + " to " + grew.to + ", but Windows"
    + " keeps C: at its old size. To use the new space, open Disk Management in"
    + " Windows, right-click C: and choose Extend Volume."
}

// The cache with the grow banner dismissed; the grow itself stays recorded
// for the rest of this run, so it does not come back on the next sample.
function dismissGrew(cached) {
  var grew = cached ? grewShape(cached.grew) : null
  if (!grew || grew.dismissed) return cached
  var next = {}
  for (var key in cached) next[key] = cached[key]
  grew.dismissed = true
  next.grew = grew
  return next
}

// What to persist under $XDG_STATE_HOME/omawin/state.json, given the sample
// that has just come in and whatever is cached now. A running sample writes
// the VM's shape, its start time and `lastSeen` — the moment we last saw it
// running, which is what "Last run" prints. A sample with no pid returns the
// previous cache untouched, so a stopped VM keeps showing its last shape and
// the time it was last up. Pure: the Service decides when to actually write.
function cacheFrom(sample, previous, now) {
  if (!sample || !sample.pid) return previous || null
  var before = previous || {}
  // No `pending` on the way out: the VM is running, so whatever Tune wrote has
  // been consumed and the live shape is the shape. That is also what clears
  // the stopped card's "Shape saved" banner on the next start.
  var next = {
    cores: sample.cores || (isFinite(before.cores) ? Number(before.cores) : 0),
    ram: sample.ram || (before.ram ? String(before.ram) : ""),
    disk: sample.disk || (before.disk ? String(before.disk) : ""),
    started: sample.started || (isFinite(before.started) ? Number(before.started) : 0),
    lastSeen: isFinite(now) ? Math.floor(now) : 0
  }
  // A grow is this start consuming a Tune that asked for a bigger disk: the
  // pending disk is the size the VM now runs with, and bigger than the one
  // it last ran with. Not merely "bigger than the cache says": after a remove
  // and a fresh install at a bigger size the cache still holds the old disk,
  // and a fresh Windows already uses all of it. A grow already recorded is
  // kept for as long as this same run lasts, which takes a start time read
  // off this sample: the cached one would make every later run "the same".
  var grew = null
  var pending = pendingShape(before)
  if (pending && pending.disk && sample.disk === pending.disk
    && DISK_SHAPE.test(String(before.disk))
    && parseInt(pending.disk, 10) > parseInt(before.disk, 10))
    grew = { from: String(before.disk), to: pending.disk }
  else if (sample.started && Number(before.started) === sample.started)
    grew = grewShape(before.grew)
  if (grew) next.grew = grew
  return next
}

// What to persist after Tune's Apply: everything the cache already held, plus
// the shape the next start will use. The VM is stopped, so there is no live
// sample to take it from and the writer's own arguments are the record. Pure:
// the Service decides when to put it on disk, as everywhere else here.
function cachePending(previous, next) {
  var before = previous || {}
  return {
    cores: isFinite(before.cores) ? Number(before.cores) : 0,
    ram: before.ram ? String(before.ram) : "",
    disk: before.disk ? String(before.disk) : "",
    started: isFinite(before.started) ? Number(before.started) : 0,
    lastSeen: isFinite(before.lastSeen) ? Number(before.lastSeen) : 0,
    pending: {
      cores: Number(next && next.cores) || 0,
      ram: next && next.ram ? String(next.ram) : "",
      disk: next && next.disk ? String(next.disk) : ""
    }
  }
}
