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
//                         frozen, cores, ram, web, cid — every 5 s (30 s with
//                         nothing installed), plus a re-sample whenever the
//                         panel opens and right after every action.
//   helpers/rdp-probe.sh  an X.224 Connection Request to 127.0.0.1:3389;
//                         every 3 s while the guest boots, every 30 s once it
//                         answers (to notice a guest reboot), never otherwise.
//
// One small file is written: $XDG_STATE_HOME/omawin/state.json, the shape of
// the VM (cores, RAM), when this run of it started and when it was last seen
// running — that is what the stopped card's pill and "Last run" show. It is
// pure cache: deleting it only blanks those two readouts until the next run.
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
  // The stopped card's two readings, live or cached, and its "Last run".
  readonly property string coresText: root.sample.cores ? String(root.sample.cores)
    : (root.cached && root.cached.cores ? String(root.cached.cores) : "—")
  readonly property string ramText: root.sample.ram ? root.sample.ram
    : (root.cached && root.cached.ram ? String(root.cached.ram) : "—")
  readonly property string lastRunText: State.lastRun(root.cached, root.nowMs)
  // The ready card's "Uptime", from /proc, so it survives a bar reload — and
  // re-evaluates every second while the panel is open, because nowMs does.
  readonly property string uptimeText: State.uptime(root.sample.started, root.nowMs)
  readonly property string failedMessage: root.desired && root.desired.failed ? root.desired.failed : ""
  readonly property bool dockerActive: root.sample.docker === "active"
  readonly property bool webUp: root.sample.web === 401

  // True while any action process is in flight; every button greys out, so a
  // second press cannot stack a stop on top of a start.
  readonly property bool busy: launchProc.running || stopProc.running || installProc.running
    || pauseProc.running || resumeProc.running

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

  // --------------------------------------------------------------- the cache
  // What a stopped VM still knows about itself: {cores, ram, started,
  // lastSeen}, written from the last running sample. Persistent user state
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
    command: ["mkdir", "-p", root.stateDir]
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

  function loadCache(text) {
    if (!root.cacheLoaded) {
      var parsed = null
      try {
        parsed = JSON.parse(String(text))
      } catch (error) {
        parsed = null
      }
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        root.cached = {
          cores: Number(parsed.cores) || 0,
          ram: parsed.ram ? String(parsed.ram) : "",
          started: Number(parsed.started) || 0,
          lastSeen: Number(parsed.lastSeen) || 0
        }
      }
    }
    root.cacheLoaded = true
  }

  // Called once per sample. State.cacheFrom decides what the cache should
  // hold; this only decides when to put it on disk.
  function updateCache(now) {
    var next = State.cacheFrom(root.sample, root.cached, now)
    if (!next || next === root.cached) return
    var previous = root.cached
    root.cached = next
    if (!root.cacheLoaded) return
    var shapeMoved = !previous || previous.cores !== next.cores
      || previous.ram !== next.ram || previous.started !== next.started
    if (!shapeMoved && now - root.cacheWrittenAt < 60000) return
    root.cacheWrittenAt = now
    cacheFile.setText(JSON.stringify(next, null, 2) + "\n")
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
    var line = String(text).replace(/\n[\s\S]*$/, "").replace(/^\s+|\s+$/g, "")
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
    if (next.pid) root.checkUnit()
    else root.sessionOpen = false

    root.nowMs = Date.now()
    root.updateCache(root.nowMs)
  }

  property Process sampleProc: Process {
    command: ["bash", root.helpers + "/vm-state.sh"]
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
    command: ["bash", root.helpers + "/rdp-probe.sh"]
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
    var message = String(text).replace(/^\s+|\s+$/g, "")
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
    root.setDesired("start")
    root.launching = true
    launchProc.running = true
  }

  function connect() {
    if (root.busy) return
    root.clearDesired()
    root.launching = true
    launchProc.running = true
  }

  property Process launchProc: Process {
    command: ["bash", root.helpers + "/launch.sh"]
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
    command: ["systemctl", "--user", "is-active", "omawin-launch"]
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
    command: ["bash", root.helpers + "/launch-result.sh"]
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

  // Open question 3: `docker compose down` on a frozen container sends
  // SIGTERM into a process that cannot answer, waits out the full 2 min grace
  // period and then SIGKILLs it — an unclean Windows shutdown. So a paused VM
  // is unpaused first and only stopped once that worked; a failed unpause
  // aborts the stop. (Stop is also disabled while a pause or unpause of the
  // user's own is in flight: both processes count in `busy`, and every button
  // reads `busy`.)
  function stop() {
    if (root.busy) return
    root.setDesired("stop")
    if (root.sample.frozen) {
      root.stopAfterResume = true
      resumeProc.running = true
      return
    }
    stopProc.running = true
  }

  property Process stopProc: Process {
    command: ["omarchy-windows-vm", "stop"]
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
    command: ["omarchy-launch-floating-terminal-with-presentation", "omarchy-windows-vm", "install"]
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

  function pause() {
    if (root.busy) return
    root.clearDesired()
    pauseProc.running = true
  }

  function resume() {
    if (root.busy) return
    root.clearDesired()
    root.stopAfterResume = false
    resumeProc.running = true
  }

  property Process pauseProc: Process {
    command: ["pkexec", "/usr/bin/docker", "pause", "omarchy-windows"]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: pauseErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) {
        var message = root.lastLine(pauseErr.text)
        if (root.dismissed(message)) root.clearDesired()
        else root.fail(message || "docker pause exited with status " + code)
      }
      root.refresh()
    }
  }

  property Process resumeProc: Process {
    command: ["pkexec", "/usr/bin/docker", "unpause", "omarchy-windows"]
    environment: ({ LC_ALL: "C" })
    stderr: StdioCollector { id: resumeErr; waitForEnd: true }
    onExited: function (code) {
      var message = root.lastLine(resumeErr.text)
      var thenStop = root.stopAfterResume
      root.stopAfterResume = false
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
      root.refresh()
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
    command: ["xdg-open", "http://127.0.0.1:8006"]
  }

  // ~/Windows, the /shared bind — the guest sees it as a network drive.
  function openShared() {
    sharedProc.running = true
  }

  property Process sharedProc: Process {
    command: ["xdg-open", root.home + "/Windows"]
  }
}
