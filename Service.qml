import QtQuick
import Quickshell
import Quickshell.Io
import "lib/State.js" as State

// Everything chaves.omawin knows and everything it does. Panel.qml owns not
// one Process and no polling: it instantiates this object, reads `state`,
// `actions`, `label`, `detail` and the readouts below, and calls start(),
// connect(), stop() or install(). The state machine itself is pure and lives
// in lib/State.js, unit-tested under node; this file is the I/O around it.
//
// Two samplers feed it, both unprivileged:
//
//   helpers/vm-state.sh   one line of key=value — installed, docker, pid,
//                         frozen, cores, ram, web, cid, disk, login — every
//                         5 s (30 s with nothing installed), plus a re-sample
//                         whenever the panel opens and right after every
//                         action.
//   helpers/rdp-probe.sh  an X.224 Connection Request to 127.0.0.1:3389;
//                         every 3 s while the guest boots, every 30 s once it
//                         answers (to notice a guest reboot), never otherwise.
//
// One small file is written: $XDG_STATE_HOME/omawin/state.json, the shape of
// the VM (cores, RAM, disk), when this run of it started, when it was last seen
// running and — after Tune — the shape the next start will use. That is what
// the stopped card's pill and "Last run" show. It is pure cache: deleting it
// only blanks those readouts until the next run.
//
// Three more actions arrived with the Tune, Login and Settings faces, all of
// them here rather than in the panel: helpers/tune.sh (the VM's shape, one
// pkexec'd write_compose), helpers/credentials.sh (the RDP login: read,
// clipboard, rewrite) and Omarchy's floating terminal around this plugin's own
// `setup polkit`, which is the only way the optional rule is ever installed.
// None of the three is in the polkit rule: they prompt, every time, on purpose.
//
// The docker CLI is called in exactly one place, Pause/Resume, and only
// through `pkexec /usr/bin/docker pause|unpause omarchy-windows` — one of the
// five command lines the polkit rule allows, spelled exactly as the rule
// spells it. Nothing here touches the Docker socket. The only other
// privileged work is inside
// `omarchy-windows-vm launch -k` / `stop`, which take the VM lock and call
// pkexec themselves — or skip it when the user opted into sudoless Docker.
// `launch -k` blocks for the whole RDP session, so it goes through
// helpers/launch.sh into the transient user unit `omawin-launch`, whose
// outcome is read back with helpers/launch-result.sh; see those two headers.
QtObject {
  id: root

  // ----------------------------------------------------------- the readouts

  // The last parsed helpers/vm-state.sh line, and that line verbatim (the IPC
  // `status` method hands it out so the widget can be checked headlessly).
  property var sample: State.parseSample("")
  property string sampleLine: ""

  // The last RDP probe, {ok: bool, at: ms}, or null when we have not probed
  // this VM instance yet. Reset to null the moment the pid changes, so a new
  // boot can never inherit the previous guest's "ready".
  property var probe: null

  // The transient the user asked for, in the shape State.classify expects.
  // Always REPLACED, never mutated in place: QML only notices the assignment.
  property var desired: ({ action: null, since: 0, failed: "" })

  // Clock for the pure state machine. Bumped on every sample, probe, action
  // and tick, which is what makes `state` re-evaluate: transients expire on
  // elapsed time alone, with no new sample to trigger them.
  property double nowMs: Date.now()

  // The state to paint. Everything the panel decides is a function of this.
  readonly property string state: State.classify(root.sample, root.probe, root.desired, root.nowMs)
  // The state the sampler alone reports, with no transient and no failure on
  // top: what "failed" shows the buttons of.
  readonly property string base: State.sampled(root.sample, root.probe)

  // While the omawin-launch unit is alive an RDP window is already open (or
  // on its way), and `launch -k` would only tell us so: Start and Connect
  // are switched off for that time rather than left as silent no-ops.
  //
  // Stop is switched off too while that unit is still booting the VM. The
  // launcher's `up_wait` holds the VM lock until dockur reports QEMU up, and
  // a `stop` pressed meanwhile does not fail — it queues on the lock, shows a
  // frozen "stopping" card for minutes, and then shuts Windows down right
  // under the RDP window that has just opened. Once the guest answers on RDP
  // the lock is long released and Stop is safe again.
  readonly property var actions: {
    var allowed = State.allowedActions(root.state, root.sample, root.base)
    if (root.sessionOpen) {
      allowed = Object.assign({}, allowed, {
        start: false, connect: false,
        stop: allowed.stop && root.state !== "booting"
      })
    }
    return allowed
  }
  // The reason the booting card gives for its greyed-out Stop.
  readonly property bool stopHeldByLauncher: root.sessionOpen && root.state === "booting"
  readonly property string label: State.label(root.state)
  // The cores·RAM pill: the live sample while the VM runs, the cache below
  // once it is off.
  readonly property string detail: State.detail(root.sample, root.cached)
  readonly property string tooltip: State.tooltip(root.state, root.sample, root.desired,
    root.cached, root.nowMs)
  // The shape Tune has written and the next start will use, or null. While it
  // is set the pill, the readouts below and the tooltip all show it instead of
  // the shape the VM last ran with — that is the whole point of writing it down.
  readonly property var pending: State.showsPending(root.sample, root.cached)
    ? State.pendingShape(root.cached) : null

  // The stopped card's readings, live or cached, and its "Last run".
  readonly property string coresText: root.pending ? String(root.pending.cores)
    : (root.sample.cores ? String(root.sample.cores)
      : (root.cached && root.cached.cores ? String(root.cached.cores) : "—"))
  readonly property string ramText: root.pending ? root.pending.ram
    : (root.sample.ram ? root.sample.ram
      : (root.cached && root.cached.ram ? String(root.cached.ram) : "—"))
  // The disk is the apparent size of ~/.windows/data.img, which is ours to read
  // whether or not the VM runs; the cache only covers a helper that reported
  // none. `diskNote` is the mockup's "from 64G": after a Tune that grows it,
  // the pair shows what the next start will make it and what it is now.
  readonly property string currentDisk: root.sample.disk ? root.sample.disk
    : (root.cached && root.cached.disk ? String(root.cached.disk) : "")
  readonly property string diskText: root.pending && root.pending.disk
    ? root.pending.disk : (root.currentDisk !== "" ? root.currentDisk : "—")
  readonly property string diskNote: root.pending && root.pending.disk
    && root.currentDisk !== "" && root.pending.disk !== root.currentDisk
    ? "from " + root.currentDisk : ""
  // The USERNAME line of the credentials file. The password is never sampled:
  // the Login face asks helpers/credentials.sh for it when it is asked to.
  readonly property string loginText: root.sample.login !== "" ? root.sample.login : "—"
  readonly property string lastRunText: State.lastRun(root.cached, root.nowMs)
  // The ready card's "Uptime", from /proc, so it survives a bar reload — and
  // re-evaluates every second while the panel is open, because nowMs does.
  readonly property string uptimeText: State.uptime(root.sample.started, root.nowMs)
  // What went wrong: a helper's own words, or, for a start or stop that ran
  // out of time, the state machine's (see State.failure).
  readonly property string failedMessage: State.failure(root.sample, root.desired, root.nowMs)
  readonly property bool dockerActive: root.sample.docker === "active"
  readonly property bool webUp: root.sample.web === 401

  // True while any action process is in flight; every button greys out, so a
  // second press cannot stack a stop on top of a start.
  readonly property bool busy: launchProc.running || stopProc.running || installProc.running
    || disconnectProc.running
    || pauseProc.running || resumeProc.running
    // The three configuration actions count too: Apply, Save and the terminal
    // that installs the polkit rule all grey every button out while they run,
    // so a start cannot be stacked on top of a compose rewrite.
    || tuneProc.running || saveProc.running || polkitProc.running

  // When the current episode began: the moment Start/Stop was pressed while a
  // transient is pending, otherwise the moment this QEMU process first showed
  // up. The second half is what the booting card's "Since" counts, and it is
  // deliberately not an uptime: it only knows what this shell has seen. The
  // real uptime is `uptimeText`, out of /proc.
  property double pidSince: 0
  readonly property double sinceBase: root.desired && root.desired.action ? root.desired.since : root.pidSince
  readonly property string sinceText: root.formatSince(root.sinceBase, root.nowMs)

  // Set by Panel.qml. Only affects how often the "Since" counter is redrawn.
  property bool panelOpen: false

  // ------------------------------------------------------------- the helpers
  // Resolved from this file's own URL, the way chaves.sysmon does it, so the
  // plugin works from any checkout and through the ~/.config/omarchy/plugins
  // symlink.
  readonly property string directory: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string helpers: directory + "/helpers"
  readonly property string home: Quickshell.env("HOME")
  // Only ever printed: the Settings face names the user the polkit rule would
  // be written for, before `setup` has written one to read the name back out of.
  readonly property string user: Quickshell.env("USER")

  // --------------------------------------------------------------- the cache
  // What a stopped VM still knows about itself: {cores, ram, disk, started,
  // lastSeen} written from the last running sample, plus {pending} after a
  // Tune — the shape the next `docker compose up` will use, which nothing else
  // can tell us while the VM is off. Persistent user state
  // rather than regeneratable cache in the XDG sense — nothing else can
  // recreate "the VM last ran at 09:15" — so it lives under XDG_STATE_HOME,
  // like the shell's own notification history. Deleting the file is safe: the
  // pill, "Cores", "RAM" and "Last run" go blank until the VM next runs.
  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/omawin"
  readonly property string cachePath: root.stateDir + "/state.json"

  property var cached: null
  // Nothing is written before the file on disk has been read (or found
  // missing), or a shell restart would overwrite a good cache with an empty
  // one from the first sample.
  property bool cacheLoaded: false
  // lastSeen moves with every 5 s sample, but "Last run" is printed to the
  // minute: writing that often would be pure churn. The shape (cores, RAM,
  // the start time) is written the moment it changes; a plain lastSeen bump
  // waits a minute.
  property double cacheWrittenAt: 0

  property Process mkdirProc: Process {
    command: ["/usr/bin/mkdir", "-p", "-m", "700", root.stateDir]
  }

  property FileView cacheFile: FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadCache(text())
    // First run: no file yet. The cache stays null and the first running
    // sample creates it.
    onLoadFailed: root.cacheLoaded = true
  }

  // The file is ours, under the user's own state directory, but it is read
  // like any other input: bounded in size, parsed, and every field checked
  // for the shape the widget prints before it is kept. Anything off goes
  // blank rather than onto the card.
  function loadCache(text) {
    if (!root.cacheLoaded) {
      var source = String(text)
      var parsed = null
      if (source.length <= 4096) {
        try {
          parsed = JSON.parse(source)
        } catch (error) {
          parsed = null
        }
      }
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        var cores = Number(parsed.cores)
        var started = Number(parsed.started)
        var lastSeen = Number(parsed.lastSeen)
        var horizon = Date.now() + 86400000
        root.cached = {
          cores: Number.isInteger(cores) && cores > 0 && cores <= 1024 ? cores : 0,
          ram: typeof parsed.ram === "string" && State.RAM_SHAPE.test(parsed.ram) ? parsed.ram : "",
          disk: typeof parsed.disk === "string" && State.DISK_SHAPE.test(parsed.disk) ? parsed.disk : "",
          started: Number.isInteger(started) && started > 0 && started * 1000 < horizon ? started : 0,
          lastSeen: Number.isInteger(lastSeen) && lastSeen > 0 && lastSeen < horizon ? lastSeen : 0,
          // State.pendingShape does the checking: a pending shape that does not
          // fit the writer's own spellings is dropped, not printed.
          pending: State.pendingShape(parsed),
          grew: State.grewShape(parsed.grew)
        }
      }
    }
    root.cacheLoaded = true
  }

  // Called once per sample. State.cacheFrom decides what the cache should
  // hold; this only decides when to put it on disk.
  function updateCache(now) {
    // A mocked sample is a picture, not a fact: it never reaches the file.
    if (root.mockLine !== "") return
    var next = State.cacheFrom(root.sample, root.cached, now)
    if (!next || next === root.cached) return
    var previous = root.cached
    root.cached = next
    if (!root.cacheLoaded) return
    var shapeMoved = !previous || previous.cores !== next.cores
      || previous.ram !== next.ram || previous.disk !== next.disk
      || previous.started !== next.started
      // A `pending` that has just been consumed by a start has to reach the
      // file at once: it is what the pill and the banner are reading.
      || (!!previous.pending !== !!next.pending)
      // So does a grow, or the banner would come back after a shell restart.
      || JSON.stringify(previous.grew || null) !== JSON.stringify(next.grew || null)
    if (!shapeMoved && now - root.cacheWrittenAt < 60000) return
    root.cacheWrittenAt = now
    cacheFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  // The running card's "extend C:" banner after a disk grow, and its ×.
  readonly property string grewNote: State.grewNote(root.sample, root.cached)

  function dismissGrew() {
    var next = State.dismissGrew(root.cached)
    if (next === root.cached) return
    root.cached = next
    if (!root.cacheLoaded) return
    root.cacheWrittenAt = Date.now()
    cacheFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  // Tune's own write: the shape the next start will use, stored beside the one
  // the VM last ran with. State.cachePending builds it, the VM being off means
  // no sample can, and State.cacheFrom drops it again the moment QEMU appears.
  function writePending(shape) {
    var next = State.cachePending(root.cached, shape)
    root.cached = next
    if (!root.cacheLoaded) return
    root.cacheWrittenAt = Date.now()
    cacheFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  // A reloaded or removed plugin must not leave a poller behind — nor the
  // password on the clipboard, if a Copy is still inside its 30 s window.
  Component.onDestruction: {
    if (root.copied) clipboardClearProc.running = true
    sampleTimer.running = false
    probeTimer.running = false
    unitTimer.running = false
    tickTimer.running = false
    revealTimer.running = false
    clipboardTimer.running = false
    ruleTimer.running = false
    sampleProc.running = false
    probeProc.running = false
    unitProc.running = false
    resultProc.running = false
  }

  Component.onCompleted: {
    mkdirProc.running = true
    // Give mkdir a tick, then read whatever is already there. FileView's
    // implicit preload may have raced the directory into existence.
    Qt.callLater(function () { cacheFile.reload() })
  }

  // --------------------------------------------------------------- the mock
  // Debug hook, driven by the panel's `mock` IPC method. While `mockLine` is
  // set the sampler and the RDP probe are bypassed and this line (plus this
  // probe verdict) stand in for them, which makes every face of the card
  // reachable — booting, ready, paused — on a machine whose VM is switched
  // off, and makes the whole state machine inspectable from the bar. Clearing
  // it hands the widget straight back to the real sampler.
  property string mockLine: ""
  property string mockProbe: ""   // "ok" | "no" | ""

  // -------------------------------------------------------------- the sample

  function refresh() {
    if (root.mockLine !== "") {
      root.applySample(root.mockLine)
      if (root.mockProbe !== "")
        root.probe = { ok: root.mockProbe === "ok", at: Date.now() }
      return
    }
    if (!sampleProc.running) sampleProc.running = true
  }

  function applySample(text) {
    var line = root.plain(String(text).replace(/\n[\s\S]*$/, ""), 512).replace(/^\s+|\s+$/g, "")
    var previous = root.sample
    var next = State.parseSample(line)
    root.sampleLine = line
    root.sample = next

    // A different pid (or none) is a different guest: the old probe result
    // says nothing about it.
    if (next.pid !== previous.pid) root.probe = null
    if (next.pid && next.pid !== previous.pid) root.pidSince = Date.now()
    if (!next.pid) root.pidSince = 0

    // The plan's rule for the transient AND for the sticky failure: both end
    // at "the next successful action or a state change". A state change here
    // is anything the state machine branches on — QEMU appearing or going
    // away (start and stop landing), the freeze flipping, the VM being
    // installed or removed.
    // One exception: Stop on a paused VM unpauses first (see stop()), so the
    // freeze flipping off is that stop's own doing, not a state change that
    // should end it — the card stays at "stopping" until QEMU is gone.
    var stopping = root.desired && root.desired.action === "stop"
    var moved = (!!next.pid !== !!previous.pid)
      || (next.frozen !== previous.frozen && !stopping)
      || (next.installed !== previous.installed)
    if (moved) root.clearDesired()
    // QEMU appearing means a pending shape has just been consumed, so the
    // "Shape saved" banner has said all it had to say.
    if (next.pid && !previous.pid) root.clearNotice()
    if (next.pid) root.checkUnit()
    else root.sessionOpen = false

    root.nowMs = Date.now()
    root.updateCache(root.nowMs)
  }

  property Process sampleProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", root.helpers + "/vm-state.sh"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: sampleOut; waitForEnd: true }
    onExited: function (code) {
      if (code === 0) root.applySample(sampleOut.text)
    }
  }

  property Timer sampleTimer: Timer {
    interval: State.sampleInterval(root.state)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // --------------------------------------------------------------- the probe

  readonly property int probeEvery: State.probeInterval(root.state)

  property Process probeProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", root.helpers + "/rdp-probe.sh"]
    environment: ({ LC_ALL: "C" })
    onExited: function (code) {
      // 0 = Connection Confirm, 1 = no/garbage reply, 2 = refused.
      root.probe = { ok: code === 0, at: Date.now() }
      root.nowMs = Date.now()
    }
  }

  property Timer probeTimer: Timer {
    interval: Math.max(1000, root.probeEvery)
    repeat: true
    running: root.probeEvery > 0 && root.mockLine === ""
    triggeredOnStart: true
    onTriggered: if (!probeProc.running) probeProc.running = true
  }

  // ---------------------------------------------------------------- the tick
  // Transients expire on elapsed time, so something has to re-evaluate the
  // state machine while nothing else is happening. One second is enough, and
  // it runs only while a transient is pending — or while the panel is open on
  // a running VM, where it is what advances the "Since" counter.

  property Timer tickTimer: Timer {
    interval: 1000
    repeat: true
    running: (root.desired && root.desired.action !== null)
      || (root.panelOpen && root.pidSince > 0)
    onTriggered: root.nowMs = Date.now()
  }

  // ------------------------------------------------------------- the desired

  function setDesired(action) {
    root.desired = { action: action, since: Date.now(), failed: "" }
    root.nowMs = Date.now()
  }

  // pkexec's wording when the user closes the authentication dialog instead
  // of answering it. That is a cancel, not a failure: the VM is exactly as it
  // was and nothing needs retrying, so the card must not go red over it.
  function dismissed(text) {
    return String(text).indexOf("Request dismissed") !== -1
  }

  // Text from a helper, systemd or the journal is data. Every sink the kit
  // gives us renders as PlainText already, but the string still gets the
  // treatment any outside input gets: C0/C1 controls and the bidi and
  // zero-width characters stripped, and a length cap.
  function plain(text, max) {
    return String(text)
      .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g, "")
      .slice(0, max || 300)
  }

  function clearDesired() {
    if (!root.desired.action && !root.desired.failed) return
    root.desired = { action: null, since: 0, failed: "" }
    root.launching = false
    root.nowMs = Date.now()
  }

  // Sticky until the next successful action or a state change. Also the
  // target of the debug IPC method, so the failed card can be looked at
  // without breaking a VM to get there.
  function fail(text) {
    var message = root.plain(text).replace(/^\s+|\s+$/g, "")
    if (message === "") return
    root.desired = { action: null, since: 0, failed: message }
    root.launching = false
    root.nowMs = Date.now()
  }

  function formatSince(from, now) {
    if (!from) return "—"
    var seconds = Math.max(0, Math.floor((now - from) / 1000))
    var rest = seconds % 60
    return Math.floor(seconds / 60) + ":" + (rest < 10 ? "0" : "") + rest
  }

  function lastLine(text) {
    var lines = String(text).split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line !== "") return line
    }
    return ""
  }

  // -------------------------------------------------------------- the launch
  // Start and Connect are the same command: `launch -k` runs `priv up_wait`,
  // which sees a running container and skips straight to xfreerdp3. The only
  // difference is the transient — Start expects QEMU to appear, Connect does
  // not — but both must be able to land in `failed`, so Connect records
  // `launching` instead.

  property bool launching: false

  // Pressing any action clears a sticky failure: the new action gets to
  // report its own outcome, and a red card from an earlier attempt must not
  // outlive a Connect that plainly worked.

  function start() {
    if (root.busy) return
    root.clearNotice()
    root.setDesired("start")
    root.launching = true
    launchProc.running = true
  }

  function connect() {
    if (root.busy) return
    root.launch()
  }

  // The unguarded half of connect(), for Resume's exit handler. It cannot go
  // through connect(): `busy` is a binding, and inside a Process's onExited
  // that binding is stale — Quickshell emits `exited` before
  // `runningChanged`, so `busy` still says the unpause is running (even
  // though resumeProc.running itself already reads false) and connect()'s
  // guard dropped the reconnect on the floor, silently. Reproduced with a
  // stubbed Service under quickshell: busy=true inside resumeProc.onExited,
  // resumeProc.running -> false logged only after it. Nothing else can be in
  // flight there: resume() checked `busy` when it was pressed and only the
  // unpause has run since.
  function launch() {
    root.clearDesired()
    root.clearNotice()
    root.launching = true
    launchProc.running = true
  }

  property Process launchProc: Process {
    command: ["/usr/bin/bash", root.helpers + "/launch.sh"]
    stdout: StdioCollector { id: launchOut; waitForEnd: true }
    onExited: function (code) {
      var message = root.lastLine(launchOut.text)
      if (code !== 0) {
        if (root.dismissed(message)) root.clearDesired()
        else root.fail(message || "could not start the omawin-launch unit")
      } else {
        // "started" or "already-running": either way there is a unit whose
        // outcome we want, so start watching it.
        root.unitWatch = true
      }
      root.refresh()
    }
  }

  // ---------------------------------------------------- watching omawin-launch
  // The unit outlives the action process by design (it IS the RDP session),
  // so the exit code of launch.sh says nothing about whether the VM came up.
  // Poll is-active every 2 s and, the first time the unit is not running any
  // more, ask helpers/launch-result.sh what happened. No triggeredOnStart:
  // systemd-run returns as the unit is being started and an immediate poll
  // could race it into a phantom "already gone".

  property bool unitWatch: false

  // True while the unit is alive, i.e. while an RDP window is open or about
  // to be. Kept current by the 2 s watch after a launch from this shell, and
  // by one is-active per sample while QEMU runs, so a session that predates
  // a bar reload (or was started from a terminal) is picked up within 5 s.
  property bool sessionOpen: false

  property Timer unitTimer: Timer {
    interval: 2000
    repeat: true
    running: root.unitWatch
    onTriggered: root.checkUnit()
  }

  function checkUnit() {
    if (!unitProc.running) unitProc.running = true
  }

  property Process unitProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "5", "/usr/bin/systemctl", "--user", "is-active", "omawin-launch"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: unitOut; waitForEnd: true }
    // is-active exits non-zero for everything but "active", so the code is
    // ignored and the word is what counts.
    onExited: function (code) {
      var text = root.lastLine(unitOut.text)
      var alive = text === "active" || text === "activating" || text === "reloading" || text === "deactivating"
      root.sessionOpen = alive
      if (alive || !root.unitWatch) return
      root.unitWatch = false
      resultProc.running = true
    }
  }

  property Process resultProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", root.helpers + "/launch-result.sh"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: resultOut; waitForEnd: true }
    onExited: function (code) {
      var text = root.lastLine(resultOut.text)
      root.launching = false
      if (text === "ok" || text === "" || root.dismissed(text)) root.clearDesired()
      else root.fail(text)
      root.refresh()
    }
  }

  // ---------------------------------------------------------------- the stop
  // Short and non-interactive, so it runs as a plain Process with its stderr
  // collected; `omarchy-windows-vm stop` does one `pkexec … __priv down`.

  // `docker compose down` on a frozen container sends
  // SIGTERM into a process that cannot answer, waits out the full 2 min grace
  // period and then SIGKILLs it — an unclean Windows shutdown. So a paused VM
  // is unpaused first and only stopped once that worked; a failed unpause
  // aborts the stop. (Stop is also disabled while a pause or unpause of the
  // user's own is in flight: both processes count in `busy`, and every button
  // reads `busy`.)
  function stop() {
    if (root.busy) return
    root.clearNotice()
    root.setDesired("stop")
    if (root.sample.frozen) {
      root.stopAfterResume = true
      resumeProc.running = true
      return
    }
    stopProc.running = true
  }

  property Process stopProc: Process {
    command: ["/usr/bin/omarchy-windows-vm", "stop"]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: stopErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) {
        var message = root.lastLine(stopErr.text)
        if (root.dismissed(message)) root.clearDesired()
        else root.fail(message || "omarchy-windows-vm stop exited with status " + code)
      }
      root.refresh()
    }
  }

  // ------------------------------------------------------------- the install
  // Omarchy's installer is a gum wizard: it has to land in a terminal, in the
  // same wrapper Omarchy uses for its own TUI flows.

  function install() {
    if (root.busy) return
    installProc.running = true
  }

  property Process installProc: Process {
    command: ["/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation", "/usr/bin/omarchy-windows-vm", "install"]
    onExited: function (code) { root.refresh() }
  }

  // ------------------------------------------------------- pause and resume
  // The one place the docker CLI is used, and the only one that needs the
  // container's name: `pkexec /usr/bin/docker pause|unpause omarchy-windows`,
  // character for character the command lines polkit/49-omawin.rules.in
  // allows, so the rule makes them promptless and anything else still
  // prompts. Both are short and non-interactive, so they run as plain
  // Processes with their stderr collected, exactly like stop.

  // Set when Stop unpauses first (see stop()): the stop follows the unpause
  // rather than the user pressing Resume.
  property bool stopAfterResume: false

  // Pause disconnects the RDP session first. The freeze stops the guest's RDP
  // server too, so an open xfreerdp window would sit on a frozen picture until
  // its connection timed out (seconds, or never) and every click made on it
  // meanwhile would be queued in the socket and delivered to Windows on
  // resume. Stopping our own omawin-launch unit closes the window cleanly
  // (the launcher exits 0 with "RDP session closed. Windows VM is still
  // running.") and only then is the container frozen. Resume reopens it, see
  // resume().
  function pause() {
    if (root.busy) return
    root.clearDesired()
    root.clearNotice()
    root.pauseClosedWindow = false
    if (root.sessionOpen) {
      disconnectProc.running = true
      return
    }
    pauseProc.running = true
  }

  property Process disconnectProc: Process {
    command: ["/usr/bin/systemctl", "--user", "stop", "omawin-launch"]
    environment: ({ LC_ALL: "C" })
    onExited: function (code) {
      // Whether or not the unit was still there, nothing holds the RDP
      // session now; freeze.
      root.sessionOpen = false
      root.pauseClosedWindow = true
      pauseProc.running = true
    }
  }

  // Resume unfreezes and then reopens the RDP window, because Pause closed it:
  // "Resume" that left the user staring at no window and needing Connect too
  // was the confusing half of the pause cycle. The reconnect is the same
  // launch unit Connect uses; up_wait sees the container already running and
  // goes straight to xfreerdp. It is started through launch(), not connect():
  // see the note there. (A Resume that is really the first half of a Stop,
  // stopAfterResume, reopens nothing — it stops instead.)
  function resume() {
    if (root.busy) return
    root.clearDesired()
    root.stopAfterResume = false
    root.reconnectAfterResume = true
    resumeProc.running = true
  }

  property bool reconnectAfterResume: false
  // Pause had to close the RDP window before freezing (a frozen guest would
  // hang the client). Without the polkit rule the dialog only comes after
  // that, so a dismissed one leaves the VM running with no window. It is not
  // reopened for the user: without the rule that is a second dialog (launch's
  // own pkexec up_wait) right after they said no, and a "Failed to start"
  // notification from the launcher if they say no again. The card says what
  // happened and Connect is one click.
  property bool pauseClosedWindow: false

  property Process pauseProc: Process {
    command: ["/usr/bin/pkexec", "/usr/bin/docker", "pause", "omarchy-windows"]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: pauseErr; waitForEnd: true }
    onExited: function (code) {
      var closedWindow = root.pauseClosedWindow
      root.pauseClosedWindow = false
      if (code !== 0) {
        var message = root.lastLine(pauseErr.text)
        if (root.dismissed(message)) {
          root.clearDesired()
          if (closedWindow)
            root.notice("Pause cancelled. The VM is still running; press Connect to reopen the window.", true)
        } else root.fail(message || "docker pause exited with status " + code)
      }
      root.refresh()
    }
  }

  property Process resumeProc: Process {
    command: ["/usr/bin/pkexec", "/usr/bin/docker", "unpause", "omarchy-windows"]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: resumeErr; waitForEnd: true }
    onExited: function (code) {
      var message = root.lastLine(resumeErr.text)
      var thenStop = root.stopAfterResume
      var thenConnect = root.reconnectAfterResume
      root.stopAfterResume = false
      root.reconnectAfterResume = false
      if (code !== 0) {
        // Also aborts a Stop that was waiting on this unpause: clearDesired
        // drops the "stop" transient, fail() replaces it with the message.
        if (root.dismissed(message)) root.clearDesired()
        else root.fail(message || "docker unpause exited with status " + code)
        root.refresh()
        return
      }
      if (thenStop) {
        stopProc.running = true
        return
      }
      if (thenConnect) {
        root.launch()
        return
      }
      root.refresh()
    }
  }

  // ---------------------------------------------------------- the notice
  // The one-line banner the configuration faces answer with: green after a
  // shape or a password was written, urgent with the helper's own stderr when
  // one was refused. It is NOT the sticky failure — a refused compose rewrite
  // changes nothing about the VM, so the card must not go red and claim the VM
  // failed. Cleared by the next Start (the shape it describes is in use from
  // then on), by the VM coming up, and by opening either face again.
  property string noticeText: ""
  property bool noticeOk: false

  function notice(text, ok) {
    root.noticeText = root.plain(text, 400).replace(/^\s+|\s+$/g, "")
    root.noticeOk = !!ok
  }

  function clearNotice() {
    root.noticeText = ""
    root.noticeOk = false
  }

  // ----------------------------------------------------------- the limits
  // What the Tune face is allowed to offer, read once per visit: nproc, the
  // machine's total RAM, the free space where data.img lives and the size that
  // image already has. All four are plain unprivileged readings and none of
  // them needs the VM; see helpers/tune.sh.

  property var limits: null
  readonly property int hostCores: root.limits && root.limits.cores > 0 ? root.limits.cores : 0
  readonly property int hostRamGb: root.limits && root.limits.ram > 0 ? root.limits.ram : 0
  readonly property int freeGb: root.limits && root.limits.free >= 0 ? root.limits.free : -1
  // The disk and the login are on that line too, and are checked here, but the
  // card reads both off the 5 s sampler: they are the same two files.

  function readLimits() {
    if (!limitsProc.running) limitsProc.running = true
  }

  property Process limitsProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", root.helpers + "/tune.sh", "limits"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: limitsOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      var fields = {}
      var parts = root.plain(root.lastLine(limitsOut.text), 200).split(/\s+/)
      for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=")
        if (eq > 0) fields[parts[i].substring(0, eq)] = parts[i].substring(eq + 1)
      }
      root.limits = {
        cores: /^[0-9]{1,4}$/.test(fields.cores) ? parseInt(fields.cores, 10) : 0,
        ram: /^[0-9]{1,6}$/.test(fields.ram) ? parseInt(fields.ram, 10) : 0,
        free: /^[0-9]{1,9}$/.test(fields.free) ? parseInt(fields.free, 10) : -1,
        disk: State.DISK_SHAPE.test(fields.disk || "") ? fields.disk : "",
        login: State.LOGIN_SHAPE.test(fields.login || "") ? fields.login : ""
      }
    }
  }

  // ------------------------------------------------------------- the tune
  // One privileged action, `__priv write_compose`, with the login read out of
  // the credentials file by the helper and never seen here. It is the same
  // action Omarchy's install wizard ends on; nothing is re-downloaded and
  // data.img is kept. Deliberately not in the polkit rule: this prompts.
  //
  // The written shape only takes effect at the next `docker compose up`, so it
  // goes into the cache as `pending` and the card says "next start".

  signal shapeApplied()

  property var tuneShape: ({ cores: 0, ram: "", disk: "" })

  function applyShape(cores, ram, disk) {
    if (root.busy) return
    if (!(cores > 0) || !State.RAM_SHAPE.test(String(ram)) || !State.DISK_SHAPE.test(String(disk))) return
    root.clearNotice()
    root.tuneShape = { cores: Math.floor(cores), ram: String(ram), disk: String(disk) }
    tuneProc.running = true
  }

  property Process tuneProc: Process {
    command: ["/usr/bin/bash", root.helpers + "/tune.sh", "apply",
      "--cores", String(root.tuneShape.cores),
      "--ram", root.tuneShape.ram,
      "--disk", root.tuneShape.disk]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: tuneErr; waitForEnd: true }
    onExited: function (code) {
      var message = root.lastLine(tuneErr.text)
      if (code === 0) {
        var shape = root.tuneShape
        var grew = root.currentDisk !== "" && shape.disk !== root.currentDisk
        root.writePending(shape)
        root.notice("Shape saved. The next start runs with "
          + State.shape(shape.cores, shape.ram, shape.disk) + "."
          + (grew ? " Windows sees the extra space as unallocated; extend C: in Disk Management once it is up." : ""),
          true)
        root.shapeApplied()
      } else if (root.dismissed(message)) {
        // The authentication dialog was closed: nothing was written, nothing to
        // report. The face stays as it was, with its controls still set.
        root.clearNotice()
      } else {
        root.notice(message || "could not write the VM configuration", false)
      }
      root.readLimits()
      root.refresh()
    }
  }

  // ------------------------------------------------------------ the login
  // The RDP login, straight out of ~/.config/windows/credentials — the file
  // omarchy-windows-vm's own launch reads for xfreerdp. Four one-shot calls
  // into helpers/credentials.sh, none of which puts the password in an
  // argument: it is printed on stdout for Reveal, piped to wl-copy for Copy,
  // and read from stdin for Save.

  signal passwordSaved()

  // Only set while Reveal is showing it, cleared by the 15 s timer, by the
  // panel closing (Panel.qml calls maskPassword()) and by a failed read.
  property string revealedPassword: ""
  readonly property bool revealed: root.revealedPassword !== ""
  // Set for the few seconds after Copy, so the button can say so.
  property bool copied: false

  function revealPassword() {
    if (passwordProc.running) return
    passwordProc.running = true
  }

  function maskPassword() {
    root.revealedPassword = ""
    revealTimer.running = false
  }

  property Process passwordProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", root.helpers + "/credentials.sh", "password"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: passwordOut; waitForEnd: true }
    stderr: StdioCollector { id: passwordErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) {
        root.notice(root.lastLine(passwordErr.text) || "could not read the stored password", false)
        return
      }
      // Only the trailing newline the helper's printf added is dropped: a
      // password may legitimately start or end with a space, so lastLine's trim
      // would show a different password than the one that logs in. `plain`
      // cannot alter the rest — the writer's rule is printable ASCII — and the
      // cap is that rule's 64 characters.
      root.revealedPassword = root.plain(String(passwordOut.text).replace(/\n$/, ""), 64)
      revealTimer.restart()
    }
  }

  // Re-masks by itself: a password left on screen is the one thing this face
  // must not do. The panel closing does the same, immediately.
  property Timer revealTimer: Timer {
    interval: 15000
    repeat: false
    onTriggered: root.maskPassword()
  }

  function copyPassword() {
    if (copyProc.running) return
    copyProc.running = true
  }

  property Process copyProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", root.helpers + "/credentials.sh", "copy"]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: copyErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) {
        root.notice(root.lastLine(copyErr.text) || "could not reach the clipboard", false)
        return
      }
      root.copied = true
      clipboardTimer.restart()
    }
  }

  // The clipboard is cleared 30 s later rather than left holding the password.
  // The helper only clears it if it still holds the password: anything the
  // user copied since is left alone. Clipboard history never saw it, because
  // Copy marks it sensitive.
  property Timer clipboardTimer: Timer {
    interval: 30000
    repeat: false
    onTriggered: {
      root.copied = false
      clipboardClearProc.running = true
    }
  }

  property Process clipboardClearProc: Process {
    command: ["/usr/bin/bash", root.helpers + "/credentials.sh", "clear"]
    environment: ({ LC_ALL: "C" })
  }

  // Save rewrites the compose (one authorisation, the same write_compose Tune
  // uses, so the copy of the password inside it agrees) and then the
  // credentials file. The shape goes along unchanged: the writer takes all six
  // fields or none, and it is the shape the next start will use, a pending
  // Tune's disk included, or saving would undo that grow. With no shape known there is nothing to send, and the panel
  // says so rather than guessing — hence the guard here too.
  readonly property bool canSavePassword: root.coresText !== "—" && root.ramText !== "—"
    && root.currentDisk !== ""

  property string pendingPassword: ""

  // The helper's own rule, checked here too: ^[[:print:]]{1,64}$ under LC_ALL=C
  // is ASCII 0x20 to 0x7e. Saying so is friendlier than a button that looks
  // pressed and does nothing.
  readonly property var passwordShape: /^[ -~]{1,64}$/

  function savePassword(text) {
    if (root.busy) return
    var value = String(text)
    if (!root.passwordShape.test(value)) {
      root.notice("The password must be 1 to 64 printable characters.", false)
      return
    }
    if (!root.canSavePassword) return
    root.clearNotice()
    root.pendingPassword = value
    saveProc.running = true
  }

  property Process saveProc: Process {
    command: ["/usr/bin/bash", root.helpers + "/credentials.sh", "write",
      "--cores", root.coresText, "--ram", root.ramText, "--disk", root.diskText]
    environment: ({ LC_ALL: "C" })
    stdinEnabled: true
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    // The new password crosses to the helper here and nowhere else: on stdin,
    // never in argv, and dropped from this object the moment it is written.
    onStarted: {
      write(root.pendingPassword + "\n")
      root.pendingPassword = ""
      stdinEnabled = false
    }
    onExited: function (code) {
      var message = root.lastLine(saveErr.text)
      root.pendingPassword = ""
      if (code === 0) {
        root.maskPassword()
        root.notice("Password saved. Connect will use it from now on.", true)
        root.passwordSaved()
      } else if (root.dismissed(message)) {
        root.clearNotice()
      } else {
        root.notice(message || "could not save the password", false)
      }
      root.refresh()
    }
  }

  // ------------------------------------------------------- the polkit rule
  // The optional rule that makes Start, Stop, Pause and Resume promptless.
  // Installing it needs root, so it happens where root belongs: Omarchy's
  // floating terminal, running this plugin's own `setup polkit`, which prints
  // the rule in full and asks before writing anything. The widget only reads
  // the user-owned copy setup leaves behind — /etc/polkit-1/rules.d is
  // root:polkitd 0750 and cannot be looked at from here at all.

  property bool rulePresent: false
  property string ruleUser: ""
  property double ruleSince: 0

  function readRule() {
    if (!ruleProc.running) ruleProc.running = true
  }

  property Process ruleProc: Process {
    command: ["/usr/bin/timeout", "-k", "2", "5", "/usr/bin/bash", root.helpers + "/rule-state.sh"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: ruleOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      var fields = {}
      var parts = root.plain(root.lastLine(ruleOut.text), 200).split(/\s+/)
      for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=")
        if (eq > 0) fields[parts[i].substring(0, eq)] = parts[i].substring(eq + 1)
      }
      root.rulePresent = fields.present === "1"
      root.ruleUser = /^[a-z_][a-z0-9_-]{0,31}$/.test(fields.user || "") ? fields.user : ""
      root.ruleSince = /^[0-9]{1,12}$/.test(fields.since || "") ? Number(fields.since) : 0
    }
  }

  // "12 Sep 2026", the date the copy was written. Spelled out by hand for the
  // same reason State.lastRun is: toLocaleString would follow two different
  // locales in QML and in node.
  readonly property string ruleSinceText: root.ruleSince > 0
    ? State.dateText(root.ruleSince * 1000) : ""

  property bool ruleRemoving: false

  // Omarchy's floating-terminal wrapper joins its arguments into ONE shell
  // command string (`cmd="$*"` into `bash -c`), so the only argument that is
  // not a constant is quoted here: a plugin directory with a space in it would
  // otherwise split into two words, and anything shell-ish in the path would be
  // interpreted. Single quotes, with any single quote in the path escaped the
  // POSIX way.
  readonly property string setupCommand:
    "'" + root.directory.replace(/'/g, "'\\''") + "/setup'"

  function installRule() {
    if (root.busy) return
    root.ruleRemoving = false
    root.ruleExpected = true
    polkitProc.running = true
  }

  function removeRule() {
    if (root.busy) return
    root.ruleRemoving = true
    root.ruleExpected = false
    polkitProc.running = true
  }

  property Process polkitProc: Process {
    command: root.ruleRemoving
      ? ["/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation",
        "/usr/bin/sudo", root.setupCommand, "polkit", "--remove"]
      : ["/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation",
        "/usr/bin/sudo", root.setupCommand, "polkit"]
    onExited: function (code) {
      // The terminal is another window and this process is only its launcher:
      // it returns while the user is still reading the rule, and its exit code
      // says nothing about what they answered. So the copy on disk is asked
      // again now and then for the next two minutes, and the switch follows by
      // itself the moment `setup` has written (or deleted) it.
      root.readRule()
      root.rulePolls = 40
      root.refresh()
    }
  }

  // What the terminal was opened to do, and how many 3 s checks are left before
  // the widget stops waiting for it to have happened.
  property bool ruleExpected: false
  property int rulePolls: 0

  property Timer ruleTimer: Timer {
    interval: 3000
    repeat: true
    running: root.rulePolls > 0
    onTriggered: {
      root.rulePolls -= 1
      // Either the user has answered, or they have not and there is nothing
      // more to learn by asking again.
      if (root.rulePresent === root.ruleExpected) root.rulePolls = 0
      else root.readRule()
    }
  }

  // ---------------------------------------------------- the two xdg-opens
  // Neither is privileged and neither changes the VM, so neither counts in
  // `busy` and neither can fail the card: the handler is somebody else's
  // window from here on.

  // The dockur web viewer, behind basic auth with the VM's own user and
  // password (the compose sets PROTECT: "Y"). The only way to watch a first
  // install, which is why its button is live while the VM boots.
  function openWeb() {
    webProc.running = true
  }

  property Process webProc: Process {
    command: ["/usr/bin/xdg-open", "http://127.0.0.1:8006"]
  }

  // ~/Windows, the /shared bind — the guest sees it as a network drive.
  function openShared() {
    sharedProc.running = true
  }

  property Process sharedProc: Process {
    command: ["/usr/bin/xdg-open", root.home + "/Windows"]
  }
}
