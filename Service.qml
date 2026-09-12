import QtQuick
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
// Nothing here touches the Docker socket or the docker CLI, and nothing here
// runs pkexec or sudo. The only privileged work is inside
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
  readonly property var actions: {
    var allowed = State.allowedActions(root.state, root.sample, root.base)
    if (root.sessionOpen) {
      allowed = Object.assign({}, allowed, { start: false, connect: false })
    }
    return allowed
  }
  readonly property string label: State.label(root.state)
  // No cores/RAM cache yet — that is phase 4, so a stopped VM shows nothing
  // and only a running one fills the pill.
  readonly property string detail: State.detail(root.sample, null)
  readonly property string tooltip: State.tooltip(root.state, root.sample, root.desired)
  readonly property string failedMessage: root.desired && root.desired.failed ? root.desired.failed : ""
  readonly property bool dockerActive: root.sample.docker === "active"
  readonly property bool webUp: root.sample.web === 401

  // True while any action process is in flight; every button greys out, so a
  // second press cannot stack a stop on top of a start.
  readonly property bool busy: launchProc.running || stopProc.running || installProc.running

  // When the current episode began: the moment Start/Stop was pressed while a
  // transient is pending, otherwise the moment this QEMU process first showed
  // up. The second half is what the booting card's "Since" counts, and it is
  // deliberately not an uptime: it only knows what this shell has seen. A real
  // uptime needs the phase 4 cache.
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
    var moved = (!!next.pid !== !!previous.pid)
      || (next.frozen !== previous.frozen)
      || (next.installed !== previous.installed)
    if (moved) root.clearDesired()
    if (next.pid) root.checkUnit()
    else root.sessionOpen = false

    root.nowMs = Date.now()
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

  function stop() {
    if (root.busy) return
    root.setDesired("stop")
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

  // ---------------------------------------------------------------- phase 4

  // TODO(phase 4): xdg-open http://127.0.0.1:8006 — the dockur web viewer,
  // behind basic auth with the VM's own user and password (PROTECT: "Y").
  // The only way to watch a first install. Its button is drawn disabled.
  function openWeb() {}

  // TODO(phase 4): xdg-open ~/Windows — the /shared bind. Its button is drawn
  // disabled.
  function openShared() {}

  // TODO(phase 4): Pause/Resume through
  // `pkexec /usr/bin/docker pause|unpause omarchy-windows`, and the
  // {cores, ram, lastRun} cache under $XDG_STATE_HOME/omawin/ that fills the
  // stopped card's pill, "Last run" and the ready card's "Uptime".
}
