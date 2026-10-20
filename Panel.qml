import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "lib/State.js" as State
import "lib/IpcOwner.js" as IpcOwner

// The bar glyph and the popup card of chaves.omawin, and nothing else: every
// decision here is a read of `service.state` or `service.actions`, every
// button calls a Service method, and no Process is started from this file.
// Service.qml next door owns the samplers, the timers and the actions.
//
// The card is eight faces of the same column: hero, an indeterminate progress
// bar while a transient is pending, a caption line or two columns of info
// pairs depending on the state, the failure block, and one or two rows of
// equal-width buttons. Which of those are visible is the only thing that
// changes between states — the layout, the paddings and the type sizes are the
// shell's own tokens throughout, so the card re-skins with the theme exactly
// like the first-party panels.
//
// On top of those eight states there are sub-faces, `face`: Settings, a list
// of rows, and the faces they open: Tune (the VM's shape), Login (the stored
// RDP credentials, with Change… opening its fields in place, the
// `updatePassword` face), Back up, Passwordless actions, Key binding and
// Remove. Each replaces the body of the same card and comes back with ‹ Back
// at the top right (or Esc), where the gear that opens Settings sits on the
// live faces. The state machine keeps running underneath, so the faces that
// rewrite the compose or touch the disk close themselves the moment the VM
// stops being stopped.
Panel {
  id: root
  moduleName: "chaves.omawin"
  ipcTarget: "chaves.omawin"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for status() and the fail() debug method below.
  manageIpc: false

  Service {
    id: service
    // A write that went through lands back on the face it was opened from,
    // where the banner it left behind is waiting. `face` is set directly, not
    // through openFace(), which would clear that banner on the way.
    onShapeApplied: root.face = "live"
    onPasswordSaved: { root.dropPasswordField(); root.face = "login" }
    // A copy that just landed is the Backups face's open row.
    onBackupDoneChanged: if (service.backupDone !== "") root.backupPick = service.backupDone
  }

  // ------------------------------------------------------------ the palette
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.4)
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  // A caution that is not an error ("more than half this machine"): the
  // theme's own yellow. The shell hands plugins no such role, but every
  // Omarchy theme's colors.toml has `yellow`, so it is read from there, and
  // again whenever the theme's colours change. Urgent when there is none.
  property string themeYellow: ""
  readonly property color warnColor: root.themeYellow !== "" ? root.themeYellow : root.urgentColor

  property FileView themeColors: FileView {
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.themeYellow = State.themeYellow(text())
    onLoadFailed: root.themeYellow = ""
  }

  // A theme switch is pushed to Color over the shell's IPC, not through the
  // file, so its colours changing is the signal to read the file again.
  Connections {
    target: Commons.Color
    function onAccentChanged() { root.themeColors.reload() }
    function onUrgentChanged() { root.themeColors.reload() }
    function onForegroundChanged() { root.themeColors.reload() }
  }
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- the state
  readonly property string vmState: service.state
  readonly property bool failed: vmState === "failed"
  // "failed" paints the buttons of the state underneath it so the user can
  // retry, which is exactly what State.allowedActions does with `base`.
  readonly property string stateFace: root.failed ? service.base : root.vmState
  readonly property bool inTransit: vmState === "starting" || vmState === "stopping"
  // A boot that has outrun State.BOOT_PATIENCE_MS stops breathing: RDP may
  // never answer, and a glyph that pulses for the VM's whole uptime is both a
  // lie and a bar repaint 12.5 times a second.
  readonly property bool pulsing: root.inTransit || (vmState === "booting" && !service.bootOverdue)
  // The console convention (omarchy-console DESIGN.md §6), read by its rail.
  readonly property string consoleState: State.consoleState(vmState)
  readonly property bool consoleAwake: consoleState !== ""
  // Why it failed, for the rail's tag (FAILED · reason; omarchy-console §6).
  readonly property string consoleReason: consoleState === "failed" ? service.failedMessage : ""

  // Which body the card is showing: the state machine's own ("live") or one of
  // the sub-faces. Everything the live card draws is gated on `live`.
  property string face: "live"
  readonly property bool live: root.face === "live"
  // Whether the VM is off as far as the sampler is concerned — on the failed
  // card that is the state underneath. The compose can only be rewritten here,
  // so it gates Tune, Update password and both of their faces.
  readonly property bool stoppedFace: root.stateFace === "stopped"
  // No VM: Install…, or Restore… from a backup Remove VM left behind.
  readonly property bool freshFace: root.stateFace === "not-installed"
  // docker.service reported and not running: the one case the stopped card
  // mentions Docker at all. An empty reading is a sampler that hasn't said.
  readonly property bool dockerDown: service.sample.docker !== "" && !service.dockerActive

  // Keep this in step with manifest.json: it is only ever printed, on the
  // Settings pill.
  readonly property string pluginVersion: "0.5.0"

  // The path the Settings face runs `sudo … setup polkit` on, resolved from
  // this file's own location like everything else in the Service.
  readonly property string ruleUserName: service.ruleUser !== "" ? service.ruleUser : service.user

  // The glyph's colour per the mockup's "Bar glyph per state" row: dimmed
  // with nothing installed, the dim foreground when the VM is off or going
  // off, full foreground while it is alive, urgent when something failed
  // (`bar.urgent`, the colour the Updates widget uses). A boot that RDP has
  // not answered for too long holds still in the warning colour.
  readonly property color glyphColor: {
    if (root.failed) return root.urgentColor
    if (service.bootOverdue) return root.warnColor
    if (vmState === "stopped" || vmState === "stopping") return Qt.darker(barForeground, 1.4)
    return barForeground
  }
  readonly property real glyphOpacity: vmState === "not-installed" ? 0.45 : 1.0

  // Pulse while the VM is on its way up or down. Kept on its own property
  // rather than on the button's opacity, which WidgetButton already animates
  // with a 140 ms Behavior that would fight this one.
  //
  // Stepped, not tweened: Qt Quick re-renders the whole bar window for any
  // dirty item, once per compositor frame, so a per-frame opacity tween on
  // one glyph cost ~27% of the iGPU in quickshell plus ~37% in Hyprland at
  // 3440x1440@144 for as long as the state held; 12.5 frames a second reads
  // as the same breath and measured at 1-3%.
  property real pulsePhase: 1.0
  Timer {
    id: pulseTimer
    running: root.pulsing
    // 12.5 frames a second: the same 1.6 s sine breath, sampled coarsely
    // enough to cost about a tenth of a per-frame tween.
    interval: 80
    repeat: true
    triggeredOnStart: true
    property int step: 0
    onTriggered: {
      root.pulsePhase = 0.725 + 0.275 * Math.cos(2 * Math.PI * step / 20)
      step = (step + 1) % 20
    }
    onRunningChanged: if (!running) { step = 0; root.pulsePhase = 1.0 }
  }

  // Nerd Font stand-ins for the mockup's inline SVGs.
  readonly property string winGlyph: ""      // the four-pane Windows mark
  readonly property string playGlyph: ""
  readonly property string pauseGlyph: ""
  readonly property string stopGlyph: ""
  readonly property string linkGlyph: ""
  readonly property string globeGlyph: ""
  readonly property string folderGlyph: ""
  readonly property string termGlyph: ""
  // New with the sub-faces: the gear that opens Settings, the sliders of Tune,
  // the key of Login, the eye of Reveal, the clipboard, the shield of the rule,
  // the tick of Apply and Save, the chevron of Back and the stepper’s signs.
  readonly property string gearGlyph: ""
  readonly property string tuneGlyph: ""
  readonly property string keyGlyph: ""
  readonly property string eyeGlyph: ""
  readonly property string eyeOffGlyph: ""
  readonly property string copyGlyph: ""
  readonly property string shieldGlyph: ""
  readonly property string checkGlyph: ""
  readonly property string backGlyph: ""
  readonly property string restoreGlyph: ""   // a clock turning back
  readonly property string closeGlyph: ""
  readonly property string minusGlyph: ""
  readonly property string trashGlyph: ""
  readonly property string editGlyph: ""
  readonly property string keyboardGlyph: ""
  readonly property string plusGlyph: ""

  // The hero's glyph: the Windows mark, on every face, with its pause badge.
  readonly property Component winHero: Component {
    WinMark {
      markSize: Style.font.display
      markColor: root.glyphColor
      paused: root.vmState === "paused"
      // No pulse here: on the open card the progress bar already says the VM
      // is on its way, and every step of a second animation is one more
      // repaint of the whole popup (about 8% of the iGPU in Hyprland,
      // measured). The bar glyph keeps its pulse.
    }
  }

  // The one-click shortcut, for the middle button and the `primary` IPC a key
  // binding calls: Start when stopped, Connect when ready, nothing anywhere
  // else, and never anything destructive. Says what it did.
  function primary() {
    if (root.can("start")) { service.start(); return "start" }
    if (root.can("connect")) { service.connect(); return "connect" }
    return ""
  }

  // A button is live only when the state machine allows it AND no action is
  // already in flight.
  function can(name) {
    return !service.busy && !!service.actions[name]
  }

  // ------------------------------------------------------------ the faces

  // What Tune is currently offering. Seeded from the VM's own shape every time
  // the face opens, so an abandoned edit never survives into the next visit.
  property int tuneCores: 2
  property string tuneRam: "4G"
  property string tuneDisk: ""

  // The installer's disk list with 96G and 192G added, since growing a disk by
  // a little is a more common wish here than doubling it. The RAM list is
  // State.RAM_SIZES.
  readonly property var diskSizes: [32, 64, 96, 128, 192, 256, 512]

  function resetTune() {
    var cores = parseInt(service.coresText, 10)
    root.tuneCores = cores > 0 ? cores : 2
    root.tuneRam = State.RAM_SHAPE.test(service.ramText) ? service.ramText : "4G"
    root.tuneDisk = service.diskText !== "—" ? service.diskText : ""
  }

  // What the RAM chips offer, and the line under them: see State.ramChoices.
  // The VM's size, not the chip picked: picking 8G must not take a 12G chip
  // the compose was set to off the row.
  readonly property var ramChoices: State.ramChoices(service.hostRamGb, service.ramText)
  readonly property bool tuneRamBig: State.ramBig(root.tuneRam, service.hostRamGb)
  readonly property string tuneRamNote: State.tuneRamNote(root.tuneRam, service.hostRamGb)

  // The same for the disk, where the current size is always on the list even
  // when it is not one of the six the widget offers.
  readonly property var diskChoices: {
    var list = []
    for (var i = 0; i < root.diskSizes.length; i++) list.push(root.diskSizes[i])
    var now = parseInt(service.currentDisk, 10)
    if (now > 0 && list.indexOf(now) === -1) {
      list.push(now)
      list.sort(function (a, b) { return a - b })
    }
    return list
  }

  // dockur never shrinks data.img, so anything under its current size is dead.
  function diskAllowed(gb) {
    var floor = parseInt(service.currentDisk, 10)
    return !(floor > 0) || gb >= floor
  }

  // The wizard's own free-space rule, counted the way the wizard counts it: the
  // image already on disk is not subtracted. Only for a disk that grows, as in
  // tune.sh: cores and RAM allocate nothing on disk.
  readonly property int diskNeedGb: (parseInt(root.tuneDisk, 10) || 0) + 10
  readonly property bool tuneGrows: service.currentDisk === ""
    || (parseInt(root.tuneDisk, 10) || 0) > parseInt(service.currentDisk, 10)
  readonly property bool tuneRoom: service.freeGb < 0 || !root.tuneGrows
    || root.diskNeedGb <= service.freeGb
  readonly property bool tuneChanged: String(root.tuneCores) !== service.coresText
    || root.tuneRam !== service.ramText || root.tuneDisk !== service.diskText
  readonly property bool canApply: !service.busy && root.stoppedFace
    && root.tuneChanged && root.tuneRoom && root.tuneDisk !== ""

  // The line under the controls, which is the whole explanation of what Apply
  // will do — including why it is switched off.
  readonly property string tuneSummary: {
    var shape = State.shape(root.tuneCores, root.tuneRam, root.tuneDisk)
    // Only reachable with no data.img to read a size off: the writer wants all
    // six fields, so one has to be chosen rather than guessed.
    if (root.tuneDisk === "") return "No disk size yet: pick one to apply a shape."
    if (!root.tuneChanged) return "Same shape as now, " + shape + ". Nothing to apply."
    if (!root.tuneRoom)
      return "Not enough room. " + root.tuneDisk + " needs " + root.diskNeedGb
        + " GB free (disk + 10 GB), you have " + service.freeGb + " GB."
    var text = "Next start runs with " + shape + "."
    if (service.loginText !== "—") text += " Login stays " + service.loginText + "."
    text += " Omarchy asks for authorisation once."
    if (service.currentDisk !== "" && root.tuneDisk !== service.currentDisk)
      text += " Disk grows from " + service.currentDisk + "; extend C: in Windows afterwards."
    if (State.ramShort(root.tuneRam, service.memAvailKb))
      text += " Only " + State.availText(service.memAvailKb) + " of memory is free right now:"
        + " Windows would start with less than " + root.tuneRam + "."
    return text
  }

  // Save needs a password, a known shape to carry through the writer and a VM
  // that is off, for the same reason Apply does.
  readonly property bool canSave: !service.busy && root.stoppedFace
    && service.canSavePassword && service.usernameFits(newUsername.text)
    && (newPassword.text === "" || service.passwordFits(newPassword.text))
    && service.loginChanges(newUsername.text, newPassword.text)

  // Where Back leads from the Remove face, Settings or Tune, and whether the
  // user has said their files are copied out. The switch starts off on every
  // visit: Remove VM… is only pressable once it is turned on.
  property string removeFrom: "settings"
  // Settings folds its two blocks of reference text until asked: the rule's
  // command lines, and the key line with its buttons. Closed on every visit.
  property bool showRule: false
  property bool showUnit: false
  property bool keySetupOpen: false

  // Where Back leads from Backups: Settings, Remove or Tune. Tune and
  // Login go back to Settings when opened from it, to the card otherwise.
  property string backupFrom: "settings"
  property string tuneFrom: "live"
  // The backup the Backups face has open, by path: it shows its actions.
  // Empty means the newest one.
  property string backupPick: ""
  // The backup whose Delete… is asking to be confirmed, by path.
  property string backupConfirm: ""
  // The backup the Restore face would put back, and its switch, off on
  // every visit as Remove's is.
  property string restorePick: ""
  property bool restoreAck: false
  readonly property var restoreEntry: {
    var list = service.backupList
    for (var i = 0; i < list.length; i++)
      if (list[i].path === root.restorePick) return list[i]
    return null
  }
  property string loginFrom: "live"
  property bool removeAck: false

  // One step back: Update password to Login, Passwordless and Key binding to
  // Settings, the faces Settings shares with the card to wherever they were
  // opened from. On the card itself it closes it.
  // Back and Esc hold only while this face's own write is in flight: leaving
  // Update password mid-save would drop the typed password and land the
  // helper's answer on another face. Anything else that runs (a stop, a
  // pause's dialog) is no reason to trap the user on Login or Settings,
  // which every card now offers.
  readonly property bool faceWriting:
    (root.face === "tune" && service.tuneProc.running)
    || (root.face === "updatePassword" && service.saveProc.running)
    // A copy in progress is cancelled on purpose, with its own button.
    || (root.face === "backup" && service.backupProc.running)
    || (root.face === "restore" && service.restoreProc.running)

  function goBack() {
    if (root.faceWriting) return
    if (root.face === "live") root.close()
    else if (root.face === "updatePassword") root.openFace("login")
    else if (root.face === "remove") root.openFace(root.removeFrom)
    else if (root.face === "backup") root.openFace(root.backupFrom)
    else if (root.face === "rule" || root.face === "key" || root.face === "shutdown") root.openFace("settings")
    else if (root.face === "restore") root.openFace("backup")
    else if (root.face === "tune") root.openFace(root.tuneFrom)
    else if (root.face === "login") root.openFace(root.loginFrom)
    else root.openFace("live")
  }

  // Leaving Update password, by any road: the typed password goes, and so does
  // the field's hold on the keyboard. A hidden field that kept focus would
  // keep the key catcher blocked (Tab and Esc dead) and would save again on
  // Enter. openFace() does this for every face but its own; the paths that
  // set `face` directly (a save that landed, the VM starting, the card
  // closing) call it themselves.
  function dropPasswordField() {
    newPassword.text = ""
    newPassword.password = true
    newUsername.text = ""
    keyCatcher.forceActiveFocus()
  }

  function openFace(name) {
    // The faces that rewrite the compose or remove the VM exist only for one
    // that is off. Their buttons can only reach them then, but the IPC `face`
    // can be asked for one at any time: it gets the card instead.
    if (!root.stoppedFace
      && (name === "tune" || name === "updatePassword" || name === "remove"
        || (name === "restore" && !root.freshFace)))
      name = "live"
    if (name === "tune") {
      if (root.face !== "tune") root.tuneFrom = root.face === "settings" ? "settings" : "live"
      service.clearNotice()
      service.readLimits()
      root.resetTune()
    }
    if (name === "settings") {
      service.readRule()
      service.readShutdown()
      service.readKey()
      service.readBackupPlan()
      service.readBackups()
    }
    if (name === "shutdown") {
      if (root.face !== "shutdown") root.showUnit = false
      service.readShutdown()
    }
    if (name === "rule") {
      if (root.face !== "rule") root.showRule = false
      service.readRule()
    }
    if (name === "key") {
      if (root.face !== "key") root.keySetupOpen = false
      service.readKey()
    }
    if (name === "login" && root.face !== "login" && root.face !== "updatePassword")
      root.loginFrom = root.face === "settings" ? "settings" : "live"
    if (name === "remove") {
      root.removeFrom = root.face === "tune" ? "tune" : "settings"
      root.removeAck = false
    }
    if (name === "backup") {
      // Back from Restore keeps the way Backups was entered.
      if (root.face !== "restore" && root.face !== "backup")
        root.backupFrom = root.face === "tune" || root.face === "remove" || root.face === "live" ? root.face : "settings"
      // A finished or failed copy is shown once; the next visit starts over.
      if (!service.backupProc.running) service.clearBackup()
      service.readBackupPlan()
      service.readBackups()
      if (root.face !== "backup") root.backupPick = ""
      root.backupConfirm = ""
      service.backupDeleteError = ""
    }
    if (name === "restore") {
      // An outcome is kept until Done, even across the card closing; a new
      // backup picked starts over.
      if (!service.restoreProc.running && service.restorePath !== root.restorePick) service.clearRestore()
      root.restoreAck = false
      service.readBackupPlan()
    }
    if (name === "updatePassword") {
      service.clearNotice()
      newPassword.text = ""
      newPassword.password = true
      newUsername.text = service.loginText !== "—" ? service.loginText : ""
      // The field is the only thing on that face to do: give it the keyboard,
      // which is also what unblocks the panel's key catcher for typing.
      newPassword.forceActiveFocus()
    } else {
      root.dropPasswordField()
    }
    // Nothing keeps a revealed password across a face change.
    service.maskPassword()
    root.face = name
  }

  // The two faces that rewrite the compose only exist while the VM is off: the
  // write is consumed by the next `docker compose up`, and a VM that started
  // underneath would recreate its container from a file the user is still
  // editing. They close themselves rather than fail on Apply. Remove goes too:
  // it is only offered for a VM that is off. Backups stays: its list can be
  // read and pruned while Windows runs, only Back up and Restore wait.
  onVmStateChanged: {
    if (!root.stoppedFace
      && (root.face === "tune" || root.face === "updatePassword" || root.face === "remove"
        || (root.face === "restore" && !service.restoreProc.running && !root.freshFace))) {
      root.dropPasswordField()
      root.face = "live"
    }
    // A VM just removed may have left backups: the card offers Restore….
    if (root.freshFace) service.readBackups()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    service.panelOpen = opened
    if (opened) {
      service.refresh()
      // The polkit rule can have been installed or removed from a terminal
      // since the card was last open, so the switch is re-read every time.
      // So can bindings.lua, which the Key row and Settings read.
      service.readRule()
      service.readKey()
      // With no VM, the card offers Restore… beside Install… when a backup
      // is there to restore.
      if (root.freshFace) service.readBackups()
    } else {
      // A closed card keeps nothing: back to the live face, and the revealed
      // password is dropped rather than waiting out its 15 s, as is one typed
      // into Update password.
      root.dropPasswordField()
      root.face = "live"
      service.maskPassword()
    }
  }

  // ----------------------------------------------------------------- the IPC
  // One handler answers for every instance (each monitor's bar builds one):
  // lib/IpcOwner.js hands the target to the first live instance, and to the
  // next when that one goes, so the key binding survives a monitor being
  // unplugged.
  property bool ipcOwner: false

  function ipcElected(first) {
    if (!first) {
      root.ipcOwner = false
      return
    }
    // After the leaving instance's handler is gone, or Quickshell ignores
    // this one for good.
    Qt.callLater(function () { if (IpcOwner.first() === root) root.ipcOwner = true })
  }

  Component.onCompleted: IpcOwner.join(root)
  Component.onDestruction: {
    ipc.enabled = false
    IpcOwner.leave(root)
  }

  IpcHandler {
    id: ipc
    target: "chaves.omawin"
    enabled: root.ipcOwner

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // What the middle button does, for a key binding: Start when stopped,
    // Connect when ready, nothing otherwise. Answers "start", "connect" or "".
    function primary(): string { return root.primary() }
    // The headless check: the painted state, the sampler line it came from
    // and the bar tooltip, e.g. "stopped installed=1 docker=active pid= … |
    // Windows VM · STOPPED · 4 cores · 16G".
    function status(): string {
      return service.state + " " + service.sampleLine + " | " + service.tooltip
    }
    // Debug only: stand a sampler line (an RDP verdict, "ok", "no" or
    // "overdue", and a pending transient, "start" or "stop") in for the real
    // ones, so every face of the card can be looked at with the VM switched
    // off. "overdue" is "no" on a boot already State.BOOT_PATIENCE_MS old. An
    // empty line hands the widget back to the sampler. See the IPC table in
    // docs/developing.md.
    function mock(line: string, probe: string, action: string): string {
      var overdue = String(probe) === "overdue"
      service.mockLine = String(line).slice(0, 512)
      service.mockProbe = overdue ? "no" : String(probe)
      // Handing back to the sampler also drops the mocked transient, so the
      // card does not sit in "starting" for 150 s after `mock "" "" ""`.
      if (String(line) === "") service.clearDesired()
      service.refresh()
      // Every mocked boot starts its own clock, so "no" after "overdue"
      // breathes again rather than inheriting the late one.
      // QEMU has been up at least that long, so the card's Since agrees.
      if (service.state === "booting") {
        service.bootingSince = Date.now() - (overdue ? State.BOOT_PATIENCE_MS : 0)
        service.pidSince = Math.min(service.pidSince, service.bootingSince)
      }
      if (String(action) !== "") service.setDesired(String(action))
      return service.state + " " + service.sampleLine
    }
    // Debug only: paint the failed card without breaking a VM to get there.
    // Cleared by the next successful action or state change, like any other
    // failure — or at once by calling it with an empty string. See the IPC
    // table in docs/developing.md.
    function fail(text: string): string {
      if (String(text).replace(/^\s+|\s+$/g, "") === "") service.clearDesired()
      else service.fail(text)
      return service.state + " " + service.failedMessage
    }
    // Debug only: show one of the card's faces — live, tune, login,
    // updatePassword, settings, rule, key, remove or backup — without
    // pressing through to it, the way
    // `mock` reaches every state. It goes through the same openFace() the
    // buttons use, so the face is seeded the way a press would seed it; the
    // faces that only exist for a stopped VM open only on one, and nothing
    // runs. Anything else means "live".
    function face(name: string): string {
      var faces = ["live", "tune", "login", "updatePassword", "settings", "rule", "key", "shutdown", "remove", "backup", "restore"]
      root.openFace(faces.indexOf(String(name)) >= 0 ? String(name) : "live")
      return root.face
    }
  }

  // ---------------------------------------------------------- the bar glyph

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: service.tooltip
    // The glyph alone: the shell scales everything in iconComponent to one
    // icon size (omarchy#15065), so a badge in there would shrink the mark
    // whenever it shows.
    iconComponent: Component {
      Item {
        WinMark {
          anchors.centerIn: parent
          markSize: Style.bar.iconFont
          markColor: root.glyphColor
          opacity: root.glyphOpacity * (root.pulsing ? root.pulsePhase : 1.0)
        }
      }
    }

    // The pause badge on the button instead, at the mark's bottom-right
    // corner. iconSize is the shell's painted icon size; older shells have
    // none and paint the glyph at about its font size.
    PauseBadge {
      readonly property real mark: Style.bar.iconSize !== undefined ? Style.bar.iconSize : Style.bar.iconFont
      visible: root.vmState === "paused"
      x: Math.round(button.width / 2 + mark / 2 - width * 0.75)
      y: Math.round(button.height / 2 + mark / 2 - height * 0.6)
      markSize: Style.bar.iconFont
      markColor: root.glyphColor
      opacity: root.glyphOpacity * (root.pulsing ? root.pulsePhase : 1.0)
    }
    // Left opens the card; middle is the one-click shortcut from the mockup's
    // interaction table (Start when stopped, Connect when ready, nothing
    // anywhere else — never a destructive action on a single click); right
    // does nothing.
    onPressed: function (code) {
      if (code === Qt.MiddleButton) {
        root.primary()
        return
      }
      if (code === Qt.RightButton) return
      root.toggle()
    }
  }

  // ------------------------------------------------------------- the popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    // The whole card goes urgent when something failed, the way the mockup
    // marks it. localOrSurfaceSpec is the kit's override hook: hand it a
    // colour that differs from the theme's and it returns a flat border in
    // that colour, hand it the theme's own and the themed spec (gradients,
    // per-edge widths, alpha) comes back untouched.
    borderSpec: Border.localOrSurfaceSpec("popups", "border",
      root.failed ? root.urgentColor : Commons.Color.popups.border,
      Commons.Color.popups.border, Math.max(1, Style.space(2)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The kit's own instruction for a panel with an inline editor: this
      // handler takes keys BEFORE any descendant, so without `blocked` every
      // character typed into the password field would be eaten as a shortcut.
      blocked: newPassword.activeFocus || newUsername.activeFocus
      // Esc goes back one step on a sub-face and closes only from the card,
      // the way the network panel's Esc cancels its prompt before anything.
      onCloseRequested: root.goBack()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · Windows VM / STATUS · gear ----------
        // PanelHero has no per-line colour, so the whole hero goes urgent on
        // the failed card rather than only its status line. The alternative
        // was reimplementing the hero, which the kit asks us not to do.
        //
        // The sub-faces reuse it as they are: their own title under the same
        // Windows mark, and Back where the live faces have the gear: the way
        // in and the way out share the top right. Esc does the same (see
        // goBack()). No pill: the stopped card's rows already say its cores,
        // RAM and disk, and Settings carries the version in its meta line.
        PanelHero {
          id: hero
          title: root.live ? "Windows VM"
            : root.face === "tune" ? "Tune"
            : root.face === "login" ? "Login"
            : root.face === "updatePassword" ? "Login"
            : root.face === "remove" ? "Remove VM"
            : root.face === "backup" ? "Backups"
            : root.face === "restore" ? "Restore"
            : root.face === "rule" ? "Passwordless actions"
            : root.face === "shutdown" ? "Clean shutdown"
            : root.face === "key" ? "Key binding"
            : "Settings"
          meta: root.live ? service.label
            : root.face === "login" ? "Windows VM · RDP and web viewer"
            : root.face === "updatePassword" ? "Windows VM · change the login"
            : root.face === "restore" ? "Windows VM · " + (root.restoreEntry
              ? "back to " + State.whenText(root.restoreEntry.when * 1000, Date.now()) : "stopped")
            : root.face === "settings" ? "Windows VM · Omawin " + root.pluginVersion
            : root.face === "rule" || root.face === "key" || root.face === "shutdown" ? "Windows VM · this desktop"
            : "Windows VM · " + service.label.toLowerCase()
          foreground: root.failed && root.live ? root.urgentColor : root.fg
          fontFamily: root.family
          iconOpacity: root.vmState === "not-installed" && root.live ? 0.45 : 1.0
          iconComponent: winHero
          trailingControl: Component {
            Row {
              spacing: Style.space(10)

              // The way into Settings from every live face.
              Button {
                visible: root.live
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.gearGlyph
                iconSize: Style.font.bodySmall
                fontSize: Style.font.caption
                verticalPadding: Style.spacing.xs
                horizontalPadding: Style.spacing.sm
                foreground: root.fg
                fontFamily: root.family
                tooltipText: "Settings"
                opacity: 0.7
                onClicked: root.openFace("settings")
              }

              Button {
                visible: !root.live
                anchors.verticalCenter: parent.verticalCenter
                bordered: true
                iconText: root.backGlyph
                text: "Back"
                iconSize: Style.font.bodySmall
                fontSize: Style.font.caption
                verticalPadding: Style.spacing.controlPaddingY
                horizontalPadding: Style.spacing.sm
                foreground: root.fg
                fontFamily: root.family
                tooltipText: "Back · Esc"
                enabled: !root.faceWriting
                opacity: enabled ? 1.0 : 0.45
                onClicked: root.goBack()
              }
            }
          }
        }

        // ---------- Indeterminate progress while a transient runs ----------
        // The Power panel's track/fill bar with the fill sliding instead of
        // measuring: there is nothing to measure, `up_wait` reports once at
        // the end. Reversed and dim while stopping.
        Item {
          id: progress
          // starting, booting and stopping all show it, as the mockup does:
          // every one of them is a wait with nothing to measure.
          // Not once a boot is overdue: by then nothing is visibly on its way.
          visible: root.live && (root.inTransit || (root.vmState === "booting" && !service.bootOverdue))
          width: parent.width
          implicitHeight: Style.space(8)
          // The fill slides in from beyond both ends; without the clip it
          // paints across the card's padding and past its border.
          clip: true

          Rectangle {
            id: progressTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          }

          Rectangle {
            id: progressFill
            y: 0
            height: progressTrack.height
            radius: progressTrack.radius
            width: progressTrack.width * 0.38
            color: root.vmState === "stopping" ? root.dim : Commons.Color.accent

            // Stepped, not tweened: a per-frame tween repainted the popup at
            // the monitor's refresh rate for as long as a start or a first
            // boot was watched. 44 positions along the same InOutCubic sweep,
            // 40 ms apart, is the same 1.76 s pass at 25 fps: smooth enough to
            // read as motion, and the card's only animation (the hero mark
            // above does not pulse), so each step is one popup repaint. It
            // only runs while the card is actually open.
            Timer {
              id: progressTimer
              running: progress.visible && root.opened
              interval: 40
              repeat: true
              triggeredOnStart: true
              property int step: 0
              readonly property int steps: 44
              onTriggered: {
                var t = step / steps
                var eased = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2
                var reverse = root.vmState === "stopping"
                var from = reverse ? progressTrack.width : -progressFill.width
                var to = reverse ? -progressFill.width : progressTrack.width
                progressFill.x = from + (to - from) * eased
                step = (step + 1) % (steps + 1)
              }
              onRunningChanged: if (!running) step = 0
            }
          }
        }

        // ---------- The one-paragraph states ----------
        Text {
          width: parent.width
          visible: root.live && text !== ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          // The stopped card's only paragraph is the Docker warning; an
          // overdue boot's is a caution, in the warning colour.
          color: root.vmState === "stopped" ? root.urgentColor
            : service.bootOverdue ? root.warnColor : root.dim
          font.family: root.family
          font.pixelSize: Style.font.caption
          text: {
            if (root.vmState === "not-installed" && !service.x86)
              return "Omarchy's Windows VM runs on x86_64 PCs only, and this machine is " + service.machine + "."
            if (root.vmState === "not-installed")
              return "No Windows VM on this machine. The installer asks for RAM, cores, disk size and a login, then downloads Windows 11 (10–15 min). It runs in a floating terminal."
                + (service.backupList.length === 1 ? " Restore… brings back the backup you have instead."
                  : service.backupList.length > 1 ? " Restore… brings back one of your " + service.backupList.length + " backups instead." : "")
            if (root.vmState === "starting")
              return "Bringing the container up. Omarchy may ask for authorisation."
            // Past State.BOOT_PATIENCE_MS: why RDP may never answer.
            if (service.bootOverdue)
              return service.bootOverdueNote + (service.stopHeldByLauncher
                ? " The launcher still holds the VM, so Stop waits for it." : "")
            if (root.vmState === "booting" && service.stopHeldByLauncher)
              return "The launcher holds the VM while Windows boots; Stop unlocks once it answers on RDP."
            // Pause is mistaken for a way to free memory: say it isn't.
            if (root.vmState === "paused")
              return "Frozen: using no CPU, still holding "
                + (service.sample.ram ? "its " + service.sample.ram + " of RAM" : "all of its RAM")
                + ". Resume picks up where you left off. Stop frees the RAM."
            if (root.vmState === "stopped" && root.dockerDown)
              return "Docker isn't running, so Start will fail. Start it with: sudo systemctl start docker"
            if (root.vmState === "stopping")
              return "ACPI shutdown sent. Windows gets up to 2 minutes to close cleanly."
            return ""
          }
        }

        // ---------- Two columns of info pairs ----------
        Row {
          visible: root.live
            && (root.vmState === "stopped" || root.vmState === "booting" || root.vmState === "ready")
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap

            // Cores and RAM come from the cache while the VM is off, the
            // same values the bar tooltip shows through service.detail.
            InfoPair {
              visible: root.vmState === "stopped"
              label: "Cores"
              value: service.coresText
              dimValue: service.coresText === "—"
            }
            InfoPair {
              visible: root.vmState === "stopped"
              label: "RAM"
              value: service.ramText
              dimValue: service.ramText === "—"
            }
            InfoPair {
              visible: root.vmState === "stopped"
              label: "Last run"
              value: service.lastRunText
              dimValue: true
            }
            InfoPair {
              visible: root.vmState === "booting"
              label: "QEMU"
              value: "up"
            }
            InfoPair {
              visible: root.vmState === "booting"
              label: "Web 8006"
              value: service.webUp ? "up" : "—"
              dimValue: !service.webUp
            }
            InfoPair {
              visible: root.vmState === "ready"
              label: "RDP"
              value: service.sessionOpen ? "connected" : "127.0.0.1:3389"
            }
            InfoPair {
              visible: root.vmState === "ready"
              label: "Uptime"
              // Counts up while the card is open: the Service's tick timer
              // runs whenever the panel is open on a live VM.
              value: service.uptimeText !== "" ? service.uptimeText : "—"
              dimValue: service.uptimeText === ""
            }
            InfoPair {
              visible: root.vmState === "ready"
              label: "CPU"
              value: service.cpuText !== "" ? service.cpuText : "—"
              dimValue: service.cpuText === ""
            }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap

            // The key that starts Windows, from bindings.lua, or the way to
            // set one up. Docker takes the slot in the rare case it is down.
            Item {
              visible: root.vmState === "stopped" && !root.dockerDown
              width: parent.width
              implicitHeight: keyPair.implicitHeight

              InfoPair {
                id: keyPair
                label: "Key"
                value: service.keyText !== "" ? service.keyText.replace(/ \+ /g, " ") : "set up →"
                dimValue: service.keyText === ""
              }

              MouseArea {
                anchors.fill: parent
                enabled: service.keyText === ""
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openFace("key")
              }
            }

            // Only when it is down: Docker is enabled at boot on Omarchy, so
            // "active" told nobody anything, but without it Start fails.
            InfoPair {
              visible: root.vmState === "stopped" && root.dockerDown
              label: "Docker"
              value: service.sample.docker
              urgent: true
            }
            // The disk is the apparent size of ~/.windows/data.img. After a
            // Tune that grows it, the note keeps the size it still has beside
            // the size the next start will make it.
            InfoPair {
              visible: root.vmState === "stopped"
              label: "Disk"
              value: service.diskText
              // A disk waiting to grow says from what; otherwise how much of
              // it Windows has actually written.
              note: service.diskNote !== "" ? service.diskNote : service.usedText
              dimValue: service.diskText === "—"
            }
            // Plain information: the way into the Login face is the Login…
            // button in the bottom row, on every card.
            InfoPair {
              visible: root.vmState === "stopped"
              label: "Login"
              value: service.loginText
              dimValue: true
            }
            InfoPair {
              visible: root.vmState === "booting"
              label: "RDP 3389"
              value: "no answer"
              dimValue: true
            }
            InfoPair {
              visible: root.vmState === "booting"
              label: "Since"
              value: service.sinceText
            }
            InfoPair {
              visible: root.vmState === "ready"
              label: "Web"
              value: "127.0.0.1:8006"
            }
            InfoPair {
              visible: root.vmState === "ready"
              label: "Shared"
              value: "~/Windows"
              dimValue: true
            }
          }
        }

        // ---------- The failure, quoted verbatim ----------
        Item {
          visible: root.live && root.failed && service.failedMessage !== ""
          width: parent.width
          implicitHeight: failureText.implicitHeight + Style.space(12)

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.06)
          }

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.max(1, Style.space(2))
            color: root.urgentColor
          }

          Text {
            id: failureText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: service.failedMessage
            color: root.fg
            font.family: root.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- What the configuration faces answered ----------
        // The banner Tune and Update password leave behind: the accent colour
        // for a write that went through (the kit has no "ok" token — accent is
        // its positive colour), the urgent one quoting the helper's own stderr
        // for one that did not. It is not the failed card: a refused compose
        // rewrite changed nothing about the VM. Restore's own face says its
        // outcome already; the banner is for the card it lands on after.
        BannerBox {
          visible: service.noticeText !== "" && root.face !== "settings" && root.face !== "remove"
            && root.face !== "restore"
          text: service.noticeText
          accentColor: service.noticeOk ? Commons.Color.accent : root.urgentColor
        }

        // Before Start: the RAM it would start with does not fit in what is
        // free, and dockur would quietly hand Windows less.
        BannerBox {
          visible: service.ramNote !== "" && root.live
          text: service.ramNote
          accentColor: root.urgentColor
        }

        // After a start that grew the disk: Windows leaves the new space
        // unallocated, and this is the moment it matters. Until × or a stop.
        BannerBox {
          visible: service.grewNote !== "" && root.live
          text: service.grewNote
          accentColor: Commons.Color.accent
          dismissible: true
          onDismissed: service.dismissGrew()
        }

        // ---------- Actions ----------
        PanelSeparator {
          visible: root.live && root.vmState !== "not-installed" && !root.inTransit
          foreground: root.fg
        }

        // Each state shows only what it is used for: its one main action in
        // the accent, and the few it goes with. The rest (Tune, Login, Back
        // up, Web viewer on a ready VM) are rows in Settings. Connect signs in
        // by itself, so the login is only asked for by Windows' own sign-in
        // screen, in the web viewer: Copy password sits beside it while
        // Windows starts.
        Column {
          id: liveActions
          visible: root.live
          width: parent.width
          spacing: Style.space(6)

          // not-installed
          // A backup Remove VM left behind can come back instead: Restore…
          // opens the list.
          ActionRow {
            id: installRow
            visible: root.stateFace === "not-installed"
            cells: service.backupList.length > 0 ? 2 : 1
            ActionButton {
              width: installRow.cellWidth
              iconText: root.termGlyph
              text: "Install…"
              primary: true
              allowed: root.can("install")
              // The terminal is another window; while this popup holds keyboard focus
              // Hyprland will not hand it over, so close first (as the network panel does).
              onClicked: { service.install(); root.close() }
            }
            ActionButton {
              visible: service.backupList.length > 0
              width: installRow.cellWidth
              iconText: root.restoreGlyph
              text: "Restore…"
              allowed: root.can("install") && !service.busy
              onClicked: root.openFace("backup")
            }
          }

          // stopped (and the failed card that sits on top of it), and
          // stopping, which is on its way there: Start and Tune wake when it
          // lands. Tune is offered on the card and in Settings, and nowhere
          // while running: the compose it writes is read at the next start.
          ActionRow {
            id: stoppedRow
            visible: root.stateFace === "stopped" || root.stateFace === "stopping"
            cells: 1
            ActionButton {
              width: stoppedRow.cellWidth
              iconText: root.playGlyph
              text: "Start"
              primary: true
              allowed: root.can("start")
              onClicked: service.start()
            }
          }

          ActionRow {
            id: stoppedRow2
            visible: stoppedRow.visible
            cells: 2
            ActionButton {
              width: stoppedRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.can("shared")
              onClicked: service.openShared()
            }
            ActionButton {
              width: stoppedRow2.cellWidth
              iconText: root.tuneGlyph
              text: "Tune…"
              allowed: root.can("tune")
              onClicked: root.openFace("tune")
            }
          }

          // starting and booting: nothing to press until RDP answers, but
          // the web viewer shows Windows coming up, and if Windows asks for
          // its password there, Copy password has it.
          ActionRow {
            id: bootRow
            visible: root.stateFace === "starting" || root.stateFace === "booting"
            cells: 2
            ActionButton {
              width: bootRow.cellWidth
              iconText: root.globeGlyph
              text: "Web viewer"
              allowed: root.can("web")
              onClicked: service.openWeb()
            }
            ActionButton {
              width: bootRow.cellWidth
              iconText: service.copied ? root.checkGlyph : root.copyGlyph
              text: service.copied ? "Copied · 30 s" : "Copy password"
              tooltipText: "For Windows' sign-in screen in the web viewer. Cleared from the clipboard after 30 s."
              allowed: service.loginText !== "—"
              onClicked: service.copyPassword()
            }
          }

          ActionRow {
            id: bootRow2
            visible: bootRow.visible
            cells: 1
            ActionButton {
              width: bootRow2.cellWidth
              iconText: root.stopGlyph
              text: "Stop"
              allowed: root.can("stop")
              onClicked: service.stop()
            }
          }

          // ready
          ActionRow {
            id: readyRow
            visible: root.stateFace === "ready"
            cells: 1
            ActionButton {
              width: readyRow.cellWidth
              iconText: root.linkGlyph
              text: "Connect"
              primary: true
              allowed: root.can("connect")
              onClicked: service.connect()
            }
          }

          ActionRow {
            id: readyRow2
            visible: readyRow.visible
            cells: 3
            ActionButton {
              width: readyRow2.cellWidth
              iconText: root.pauseGlyph
              text: "Pause"
              tooltipText: "Freeze Windows: frees the CPU, keeps the RAM"
              allowed: root.can("pause")
              onClicked: service.pause()
            }
            ActionButton {
              width: readyRow2.cellWidth
              iconText: root.stopGlyph
              text: "Stop"
              allowed: root.can("stop")
              onClicked: service.stop()
            }
            ActionButton {
              width: readyRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.can("shared")
              onClicked: service.openShared()
            }
          }

          // paused
          ActionRow {
            id: pausedRow
            visible: root.stateFace === "paused"
            cells: 2
            ActionButton {
              width: pausedRow.cellWidth
              iconText: root.playGlyph
              text: "Resume"
              primary: true
              allowed: root.can("resume")
              onClicked: service.resume()
            }
            ActionButton {
              width: pausedRow.cellWidth
              iconText: root.stopGlyph
              text: "Stop"
              allowed: root.can("stop")
              onClicked: service.stop()
            }
          }
        }

        // ============================ Tune =================================
        // The VM's shape: cores, RAM, the guest disk. Everything here is one
        // privileged write (helpers/tune.sh → pkexec __priv write_compose) with
        // the login read out of the credentials file and passed back unchanged,
        // so the Windows account is never touched. The controls are capped by
        // what the machine has and by what dockur will accept: the disk grows
        // and never shrinks.
        Column {
          visible: root.face === "tune"
          width: parent.width
          spacing: Style.space(14)

          InfoPair {
            label: "Current tuning"
            value: service.detail
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader {
              label: "Cores"
              hint: service.hostCores > 0 ? "of " + service.hostCores + " on this machine" : ""
            }

            Row {
              spacing: Style.space(6)

              // Windows 11's minimum. A VM set to 1 by hand still shows 1 and
              // can go up, just not back down.
              ActionButton {
                iconText: root.minusGlyph
                allowed: !service.busy && root.tuneCores > 2
                onClicked: root.tuneCores = root.tuneCores - 1
              }

              InfoValue {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignHCenter
                text: String(root.tuneCores)
              }

              ActionButton {
                iconText: root.plusGlyph
                allowed: !service.busy
                  && (service.hostCores <= 0 || root.tuneCores < service.hostCores)
                onClicked: root.tuneCores = root.tuneCores + 1
              }
            }

            // Allowed, but said: with every thread given away the desktop
            // stutters whenever Windows is busy.
            Text {
              visible: service.hostCores > 0 && root.tuneCores >= service.hostCores
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.warnColor
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: "All " + service.hostCores + " threads. Omarchy will stutter whenever Windows is busy."
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader {
              label: "RAM"
              hint: service.hostRamGb > 0
                ? "of " + service.hostRamGb + "G · Windows keeps all of it"
                : "Windows keeps all of it"
            }

            // Cut off where it would leave the machine under 4 GB.
            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.ramChoices
                delegate: ActionButton {
                  required property var modelData
                  text: modelData + "G"
                  selected: root.tuneRam === modelData + "G"
                  allowed: !service.busy
                  onClicked: root.tuneRam = modelData + "G"
                }
              }
            }

            Text {
              visible: root.tuneRamNote !== ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.tuneRamBig ? root.warnColor : root.dim
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: root.tuneRamNote
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader {
              label: "Disk"
              hint: service.freeGb >= 0 ? "grows only · " + service.freeGb + " GB free" : "grows only"
            }

            // Anything at or below the size data.img already has is dead: dockur
            // refuses to shrink it, and the current size is marked as such.
            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.diskChoices
                delegate: ActionButton {
                  required property var modelData
                  text: modelData + "G" + (modelData + "G" === service.currentDisk ? " now" : "")
                  selected: root.tuneDisk === modelData + "G"
                  allowed: !service.busy && root.diskAllowed(modelData)
                  onClicked: root.tuneDisk = modelData + "G"
                }
              }
            }

            // So the only way to a smaller disk is a new VM. Said wherever a
            // smaller size is greyed out, and the line leads to the Remove face,
            // warnings and all, never straight to the remover.
            Text {
              visible: root.diskChoices.length > 0 && !root.diskAllowed(root.diskChoices[0])
              width: parent.width
              textFormat: Text.StyledText
              wrapMode: Text.WordWrap
              color: root.dim
              linkColor: root.fg
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: "A disk can't shrink. For a smaller one, <a href=\"backup\"><b>Back up →</b></a>, then <a href=\"remove\"><b>Remove VM →</b></a> and Install… again."
              onLinkActivated: function (link) {
                if ((link === "backup" || link === "remove") && root.can(link)) root.openFace(link)
              }

              HoverHandler {
                cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: root.tuneSummary
          }

          ActionRow {
            id: tuneRow
            cells: 1
            ActionButton {
              width: tuneRow.cellWidth
              iconText: root.checkGlyph
              text: "Apply…"
              allowed: root.canApply
              onClicked: service.applyShape(root.tuneCores, root.tuneRam, root.tuneDisk)
            }
          }
        }

        // ============================ Login ================================
        // ~/.config/windows/credentials, the user's own 0600 file: what
        // omarchy-windows-vm's launch hands xfreerdp and what the web viewer
        // asks for. Reveal shows the password for 15 s, Copy puts it on the
        // clipboard for 30 s, and both go through helpers/credentials.sh so the
        // password is never an argument of anything.
        Column {
          visible: root.face === "login"
          width: parent.width
          spacing: Style.space(14)

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Username"; value: service.loginText }
            InfoPair {
              label: "Password"
              value: service.revealed ? service.revealedPassword : "••••••••••••"
              dimValue: !service.revealed
            }
            InfoPair {
              label: "Stored in"
              value: "~/.config/windows/credentials"
              dimValue: true
            }
          }

          ActionRow {
            id: loginRow
            cells: 2
            ActionButton {
              width: loginRow.cellWidth
              iconText: service.revealed ? root.eyeOffGlyph : root.eyeGlyph
              text: service.revealed ? "Hide" : "Reveal"
              allowed: service.loginText !== "—"
              onClicked: service.revealed ? service.maskPassword() : service.revealPassword()
            }
            ActionButton {
              width: loginRow.cellWidth
              iconText: root.copyGlyph
              text: service.copied ? "Copied · clears in 30 s" : "Copy password"
              allowed: service.loginText !== "—"
              onClicked: service.copyPassword()
            }
          }

          PanelSeparator { foreground: root.fg }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: root.stoppedFace
              ? "Changed the password inside Windows, or want another account? Change it here so Connect keeps working."
              : "Changed the password inside Windows, or want another account? Stop the VM first: saving it here also rewrites the compose, which is only read at the next start."
          }

          // Change… opens the fields on this same face (the `updatePassword`
          // face keeps its name for the IPC and the guards that hold it).
          ActionRow {
            id: loginRow2
            cells: 1
            ActionButton {
              width: loginRow2.cellWidth
              iconText: root.editGlyph
              text: "Change…"
              allowed: !service.busy && root.stoppedFace
              onClicked: root.openFace("updatePassword")
            }
          }
        }

        // ===================== Login: Change… (in place) ====================
        // Only what this machine sends when it connects: which existing
        // Windows account, and its password. Accounts are made and changed
        // inside Windows; this is where the result is written down, into the
        // credentials file and into the compose's fallback copy of it — one
        // authorisation, stopped only. (The face keeps its old IPC name.)
        Column {
          visible: root.face === "updatePassword"
          width: parent.width
          spacing: Style.space(14)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: "Type an account that already exists in Windows. This changes what this machine sends when connecting; it can't create or rename the account."
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader { label: "Username"; hint: "letters, digits, _ and -" }

            TextField {
              id: newUsername
              width: parent.width
              foreground: root.fg
              font.family: root.family
              font.pixelSize: Style.font.caption
              maximumLength: 20
              onAccepted: if (root.canSave) service.saveLogin(text, newPassword.text)
              KeyNavigation.tab: newPassword
              KeyNavigation.backtab: newPassword
              Keys.onEscapePressed: root.goBack()
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader { label: "Password"; hint: "empty keeps the current one" }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: newPassword
                width: parent.width - eyeButton.implicitWidth - parent.spacing
                password: true
                foreground: root.fg
                font.family: root.family
                font.pixelSize: Style.font.caption
                placeholderText: "unchanged"
                onAccepted: if (root.canSave) service.saveLogin(newUsername.text, text)
                KeyNavigation.tab: newUsername
                KeyNavigation.backtab: newUsername
                // The field holds the keyboard, so the key catcher never sees
                // this Esc: it has to go back from here.
                Keys.onEscapePressed: root.goBack()
              }

              ActionButton {
                id: eyeButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: newPassword.password ? root.eyeGlyph : root.eyeOffGlyph
                allowed: true
                onClicked: newPassword.password = !newPassword.password
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: service.canSavePassword
              ? "Changed the password inside Windows? Web viewer (it signs in by itself) › Settings › Accounts › Sign-in options, then come back here."
              : "The VM's shape is not known yet, and the compose cannot be rewritten without it. Start the VM once, then come back."
          }

          ActionRow {
            id: updateRow
            cells: 2
            ActionButton {
              width: updateRow.cellWidth
              iconText: root.backGlyph
              text: "Cancel"
              allowed: !root.faceWriting
              onClicked: root.goBack()
            }
            ActionButton {
              width: updateRow.cellWidth
              iconText: root.checkGlyph
              text: "Save…"
              primary: true
              allowed: root.canSave
              onClicked: service.saveLogin(newUsername.text, newPassword.text)
            }
          }
        }

        // =========================== Settings ==============================
        // A list of rows, one per thing to look at or change: each says its
        // current value and what it does in one line, and opens its own face,
        // where the longer text sits above the button that acts. Only
        // Passwordless and Key binding live here alone; Tune, Login, Back up
        // and Remove are also reached from elsewhere.
        Column {
          visible: root.face === "settings"
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            visible: root.vmState !== "not-installed"
            text: "VM"
            foreground: root.fg
            fontFamily: root.family
          }

          SettingsRow {
            visible: root.vmState !== "not-installed"
            title: "Tune"
            value: service.detail
            tip: root.stoppedFace ? "Cores, RAM and disk for the next start." : "Stop the VM to change its cores, RAM or disk."
            allowed: root.can("tune")
            onActivated: root.openFace("tune")
          }

          SettingsRow {
            visible: root.vmState !== "not-installed"
            title: "Login"
            value: service.loginText
            tip: "The account Connect signs in with. Show, copy or change it."
            allowed: service.loginText !== "—"
            onActivated: root.openFace("login")
          }

          SettingsRow {
            visible: root.vmState === "ready" || root.vmState === "booting" || root.vmState === "starting"
            title: "Web viewer"
            value: "127.0.0.1:8006"
            tip: "Windows' screen in the browser, for when Connect can't reach it."
            allowed: root.can("web")
            onActivated: service.openWeb()
          }

          SettingsRow {
            visible: root.vmState !== "not-installed"
            title: "Backups"
            value: service.backupProc.running
              ? "copying · " + State.gbText(service.backupCopied)
              : service.backupsText
            tip: root.stoppedFace
              ? "Copies of Windows' disk and login, next to the original, so a Tune, update or Remove can be undone."
              : "Copies of Windows' disk and login. Stop the VM to make one; you can look at them now."
            allowed: true
            onActivated: root.openFace("backup")
          }

          SettingsRow {
            visible: root.vmState !== "not-installed" || service.shutdownEnabled
            title: "Clean shutdown"
            value: !service.shutdownRead ? "" : service.shutdownEnabled ? "on" : "off"
            tip: service.shutdownEnabled
              ? "A reboot or power-off waits for Windows to shut down."
              : "Omarchy gives Windows 5 seconds at a reboot, which cuts it off. This waits for it."
            allowed: true
            onActivated: root.openFace("shutdown")
          }

          PanelSectionHeader {
            text: "DESKTOP"
            foreground: root.fg
            fontFamily: root.family
          }

          SettingsRow {
            title: "Passwordless actions"
            value: service.rulePresent ? "on" : "off"
            tip: service.rulePresent
              ? "Start, Stop, Pause and Resume run without a dialog."
              : "Start, Stop, Pause and Resume without the dialog. Installing it opens a terminal."
            allowed: true
            onActivated: root.openFace("rule")
          }

          SettingsRow {
            title: "Key binding"
            value: service.keyText !== "" ? service.keyText.replace(/ \+ /g, " ") : "not set"
            tip: "One key to start Windows, or connect when it's running."
            allowed: true
            onActivated: root.openFace("key")
          }

          // The way to Remove: last on the rarest face, three deliberate steps
          // from the card (the gear, this row, the switch on the face it
          // opens), and never beside Start. Only for a VM that exists.
          PanelSeparator {
            visible: root.vmState !== "not-installed"
            foreground: root.fg
          }

          SettingsRow {
            visible: root.vmState !== "not-installed"
            title: "Remove VM…"
            danger: true
            value: service.currentDisk !== "" ? service.currentDisk + " disk" : ""
            tip: root.stoppedFace
              ? "Deletes Windows and everything in it. The Shared folder and backups stay. Install… starts a fresh one; Restore… brings a backup back."
              : "Stop the VM to remove it. To back up first, Connect and copy your files to the Shared folder."
            allowed: root.can("remove")
            onActivated: root.openFace("remove")
          }
        }

        // ====================== Passwordless actions =======================
        // The one opt-in: a polkit rule that makes Start, Stop, Pause and
        // Resume promptless for this user. It needs root, so the work happens
        // in Omarchy's floating terminal running this plugin's own `setup`,
        // which prints the rule in full and asks before writing it. The switch
        // is a picture of the user-owned copy setup leaves behind — the rules
        // directory itself cannot be read from here at all.
        Column {
          visible: root.face === "rule"
          width: parent.width
          spacing: Style.space(14)

          Row {
            width: parent.width
            spacing: Style.space(12)

            Column {
              width: parent.width - ruleSwitch.implicitWidth - parent.spacing
              spacing: Style.space(2)

              InfoValue {
                text: service.rulePresent ? "Passwordless actions · ON" : "Passwordless actions"
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.family
                font.pixelSize: Style.font.caption
                text: service.rulePresent && !service.ruleLocal
                  ? "Installed for " + root.ruleUserName + " by an older Omawin, which also lets"
                    + " SSH sessions skip the dialog. Remove the rule and install it again"
                    + " to limit it to this desktop."
                  : service.rulePresent
                  ? "Installed for " + root.ruleUserName
                    + (service.ruleSinceText !== "" ? " on " + service.ruleSinceText : "")
                    + ", as recorded by setup."
                  : "Start, Stop, Pause and Resume without the dialog."
              }
            }

            // A picture of state that happens to be pressable: it does the same
            // as the button below it, which is the only thing that can change
            // the rule.
            ToggleSwitch {
              id: ruleSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: service.rulePresent
              busy: service.busy
              foreground: root.fg
              onToggled: { service.rulePresent ? service.removeRule() : service.installRule(); root.close() }
            }
          }

          // Folded by default: read once, when deciding. The terminal `setup`
          // opens prints the full rule again before writing it.
          Text {
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            font.underline: true
            text: root.showRule ? "Hide the rule ▾" : "Show the rule ▸"

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showRule = !root.showRule
            }
          }

          // The five command lines, rendered from the same template `setup`
          // installs, so what is read here is what the terminal will show.
          Item {
            visible: root.showRule
            width: parent.width
            implicitHeight: ruleText.implicitHeight + Style.space(12)

            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
            }

            Text {
              id: ruleText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: "Allows, for " + root.ruleUserName + " at this desktop only, exactly:\n"
                + "/usr/bin/omarchy-windows-vm __priv status\n"
                + "/usr/bin/omarchy-windows-vm __priv up_wait\n"
                + "/usr/bin/omarchy-windows-vm __priv down\n"
                + "/usr/bin/docker pause omarchy-windows\n"
                + "/usr/bin/docker unpause omarchy-windows"
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: service.rulePresent
              ? "Start, Stop, Pause and Resume run without a dialog. Tune's Apply and Login's Save still ask: rewriting the VM's configuration stays behind authorisation on purpose, and it is rare."
              : "Installs /etc/polkit-1/rules.d/49-omawin.rules. Opens a terminal; sudo asks for your password once and the file is shown before it is written."
          }

          ActionRow {
            id: settingsRow
            cells: 1
            ActionButton {
              width: settingsRow.cellWidth
              iconText: root.shieldGlyph
              text: service.rulePresent ? "Remove rule…" : "Install rule…"
              allowed: !service.busy
              onClicked: { service.rulePresent ? service.removeRule() : service.installRule(); root.close() }
            }
          }

        }

        // ========================== Clean shutdown =========================
        // The second opt-in: a system unit, ordered after docker.service, whose
        // stop wakes a paused VM and stops it before Docker goes down. Omarchy
        // gives every service 5 s at a reboot, which kills Windows mid-shutdown
        // without it. Installed by `setup shutdown` in a terminal, as the rule.
        Column {
          visible: root.face === "shutdown"
          width: parent.width
          spacing: Style.space(14)

          Row {
            width: parent.width
            spacing: Style.space(12)

            Column {
              width: parent.width - unitSwitch.implicitWidth - parent.spacing
              spacing: Style.space(2)

              InfoValue {
                text: service.shutdownEnabled ? "Clean shutdown · ON" : "Clean shutdown"
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.family
                font.pixelSize: Style.font.caption
                text: service.shutdownEnabled
                  ? "A reboot or power-off waits for Windows to shut down, up to 2 minutes, and wakes a paused VM first."
                  : "Omarchy gives every service 5 seconds to stop at a reboot or power-off. Windows needs longer, so it is cut off, paused or not, as if the power went."
              }
            }

            ToggleSwitch {
              id: unitSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: service.shutdownEnabled
              busy: service.busy
              foreground: root.fg
              onToggled: { service.shutdownEnabled ? service.removeShutdown() : service.installShutdown(); root.close() }
            }
          }

          Text {
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            font.underline: true
            text: root.showUnit ? "Hide what it runs ▾" : "Show what it runs ▸"

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showUnit = !root.showUnit
            }
          }

          // The two lines of systemd/omawin-vm-shutdown.service that do
          // anything; the terminal shows the whole file before writing it.
          Item {
            visible: root.showUnit
            width: parent.width
            implicitHeight: unitText.implicitHeight + Style.space(12)

            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
            }

            Text {
              id: unitText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: "When Docker stops, just before it:\n"
                + "/usr/bin/docker unpause omarchy-windows\n"
                + "/usr/bin/docker stop -t 120 omarchy-windows"
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: service.shutdownEnabled
              ? "Removing it leaves it armed until the next reboot: stopping it now would shut Windows down."
              : "Installs /etc/systemd/system/" + service.shutdownUnit + ". Opens a terminal; sudo asks for your password once and the file is shown before it is written."
          }

          ActionRow {
            id: unitRow
            cells: 1
            ActionButton {
              width: unitRow.cellWidth
              iconText: root.shieldGlyph
              text: service.shutdownEnabled ? "Remove unit…" : "Install unit…"
              allowed: !service.busy
              onClicked: { service.shutdownEnabled ? service.removeShutdown() : service.installShutdown(); root.close() }
            }
          }
        }

        // =========================== Key binding ===========================
        // The key for `primary`: shown when bindings.lua has one, offered as
        // a line to paste when it does not. Omawin never writes the file.
        Column {
          visible: root.face === "key"
          width: parent.width
          spacing: Style.space(14)

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader {
              label: "Your key"
              hint: service.keyText !== "" ? "from bindings.lua" : "not set"
            }

            InfoValue {
              visible: service.keyText !== ""
              text: service.keyText
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: service.keyText !== ""
                ? "Starts Windows when it's stopped, connects when it's ready."
                : root.keySetupOpen
                  ? "One key to start Windows, or connect when it's running. Add this line to ~/.config/hypr/bindings.lua and save:"
                  : "One key to start Windows, or connect when it's running."
            }

            Rectangle {
              visible: service.keyText === "" && root.keySetupOpen
              width: parent.width
              implicitHeight: keyLineText.implicitHeight + Style.space(12)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)

              Text {
                id: keyLineText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                color: root.fg
                font.family: root.family
                font.pixelSize: Style.font.caption
                text: service.keyLine
              }
            }
          }

          // The action, like every other section's; it unfolds the line and
          // the two buttons that act on it.
          ActionRow {
            id: keySetupRow
            visible: service.keyText === "" && !root.keySetupOpen
            cells: 1
            ActionButton {
              width: keySetupRow.cellWidth
              iconText: root.keyboardGlyph
              text: "Set up a key…"
              allowed: true
              onClicked: root.keySetupOpen = true
            }
          }

          ActionRow {
            id: keyRow
            visible: service.keyText === "" && root.keySetupOpen
            cells: 2
            ActionButton {
              width: keyRow.cellWidth
              iconText: service.keyLineCopied ? root.checkGlyph : root.copyGlyph
              text: service.keyLineCopied ? "Copied" : "Copy line"
              allowed: true
              onClicked: service.copyKeyLine()
            }
            ActionButton {
              width: keyRow.cellWidth
              iconText: root.editGlyph
              text: "Open bindings.lua"
              allowed: true
              onClicked: { service.openBindings(); root.close() }
            }
          }

        }

        // ============================= Backups =============================
        // helpers/backup.sh plan/run/list: ~/.windows and the credentials file
        // into <name>.bak-<date> beside the VM's real folder (or $HOME), as the
        // user, VM off; and every backup already on disk, with what deleting
        // it frees. The making part has four states: the plan (with the room
        // check), copying (progress, Cancel), done, failed. The list is read
        // whatever the VM does: only making and restoring need it off.
        Column {
          id: backupFace
          visible: root.face === "backup"
          width: parent.width
          spacing: Style.space(14)

          readonly property var plan: service.backupPlan
          readonly property bool running: service.backupProc.running
          readonly property bool done: service.backupDone !== ""
          // The open row: the one picked, else the newest.
          readonly property string pick: {
            var list = service.backupList
            for (var i = 0; i < list.length; i++)
              if (list[i].path === root.backupPick) return root.backupPick
            return list.length > 0 ? list[0].path : ""
          }

          // ---- the plan
          Column {
            visible: !backupFace.running && !backupFace.done && root.stoppedFace
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair {
              label: "Windows' disk"
              value: service.currentDisk !== "" ? service.currentDisk : "—"
              note: backupFace.plan ? State.gbText(backupFace.plan.used) + " written"
                : service.backupNothingYet ? "not made yet" : ""
            }
            InfoPair {
              label: "Copy to"
              value: backupFace.plan
                ? State.tildePath(backupFace.plan.where + "/" + backupFace.plan.target, service.home) : "—"
            }
            InfoPair {
              label: "Space"
              value: !backupFace.plan ? "—"
                : backupFace.plan.reflink
                  ? "instant here · " + State.gbText(backupFace.plan.free) + " free"
                  : "needs " + State.gbText(backupFace.plan.used) + " · " + State.gbText(backupFace.plan.free) + " free"
              urgent: !!backupFace.plan && !backupFace.plan.ok
            }
          }

          Text {
            visible: !backupFace.running && !backupFace.done
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.freshFace ? root.dim
              : !root.stoppedFace ? root.warnColor
              : service.backupError !== "" || service.backupPlanError !== ""
              || (backupFace.plan && !backupFace.plan.ok) ? root.urgentColor : root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: root.freshFace ? "There's no VM now. Restore… brings one of these back as it was, where it was."
              : !root.stoppedFace ? "Stop the VM to back it up: a copy of a disk Windows is writing to would be torn. You can still look at the backups below."
              : service.backupError !== "" ? "The backup failed: " + service.backupError
              : service.backupNothingYet ? "Nothing to back up yet: Windows makes its disk the first time it starts. Start it once, then come back."
              : service.backupPlanError !== "" ? "Couldn't read the VM's size: " + service.backupPlanError
              : !backupFace.plan ? "Reading the VM's size…"
              : !backupFace.plan.ok ? "Not enough room for a full copy. Free some space, or copy ~/.windows to another drive by hand."
              : backupFace.plan.same
                ? "Copies Windows' disk and login. Same drive as the original: this saves you from a bad Tune, update or Remove, not from a dead drive. To keep a copy elsewhere, copy that folder off."
                : "Copies Windows' disk and login. On another drive than the original, so it also outlives that drive. It's a full copy, as a copy across drives always is."
          }

          ActionRow {
            id: backupRow
            visible: !backupFace.running && !backupFace.done && root.stoppedFace
            cells: 1
            ActionButton {
              width: backupRow.cellWidth
              iconText: root.copyGlyph
              text: "Back up now"
              primary: true
              allowed: root.can("backup") && !!service.backupPlan && service.backupPlan.ok
              onClicked: service.startBackup()
            }
          }

          // ---- copying
          InfoPair {
            visible: backupFace.running
            label: "Copying Windows' disk"
            value: State.gbText(service.backupCopied)
              + (backupFace.plan ? " of " + State.gbText(backupFace.plan.used) : "")
          }

          Rectangle {
            visible: backupFace.running
            width: parent.width
            height: Style.space(6)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

            Rectangle {
              height: parent.height
              color: Commons.Color.accent
              width: parent.width * Math.min(1, backupFace.plan && backupFace.plan.used > 0
                ? service.backupCopied / backupFace.plan.used : 0)
            }
          }

          Text {
            visible: backupFace.running
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: "Start stays off until the copy ends. Cancel deletes the half-made copy."
          }

          ActionRow {
            id: backupCancelRow
            visible: backupFace.running
            cells: 1
            ActionButton {
              width: backupCancelRow.cellWidth
              iconText: root.closeGlyph
              text: "Cancel"
              allowed: true
              onClicked: service.cancelBackup()
            }
          }

          // ---- done
          InfoPair {
            visible: backupFace.done
            label: "Saved to"
            value: State.tildePath(service.backupDone, service.home)
          }

          Text {
            visible: backupFace.done
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: "It's first in the list below."
          }

          ActionRow {
            id: backupDoneRow
            visible: backupFace.done
            cells: 2
            ActionButton {
              width: backupDoneRow.cellWidth
              iconText: root.folderGlyph
              text: "Show in folder"
              allowed: true
              onClicked: { service.openBackup(); root.close() }
            }
            ActionButton {
              width: backupDoneRow.cellWidth
              iconText: root.checkGlyph
              text: "Done"
              allowed: true
              onClicked: service.clearBackup()
            }
          }

          // ---- the backups on disk
          Item {
            visible: !backupFace.running
            width: parent.width
            implicitHeight: listHeader.implicitHeight

            PanelSectionHeader {
              id: listHeader
              anchors.left: parent.left
              text: "ON DISK" + (service.backupListRead ? " · " + service.backupList.length : "")
              foreground: root.fg
              fontFamily: root.family
            }

            PanelSectionHeader {
              anchors.right: parent.right
              visible: service.backupList.length > 0
              text: "OWN SIZE"
              foreground: root.fg
              fontFamily: root.family
            }
          }

          Text {
            visible: service.backupDeleteError !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.urgentColor
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: "Couldn't delete it: " + service.backupDeleteError
          }

          Text {
            visible: !backupFace.running && service.backupListRead && service.backupList.length === 0
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: root.freshFace ? "No backups found, beside where the VM was or on your drives."
              : "No backups yet. Back up now makes the first, next to the VM."
          }

          Column {
            visible: !backupFace.running && service.backupList.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: service.backupList

              BackupRow {
                required property var modelData
                entry: modelData
                open: modelData.path === backupFace.pick
              }
            }
          }
        }

        // ============================= Restore =============================
        // helpers/backup.sh restore: a safety backup of the VM as it is, the
        // chosen backup staged beside it, the compose rewritten only if the
        // login or the disk differs (the one dialog), then the swap. Before:
        // what happens and a switch, as Remove asks. During: the step and
        // Cancel while it copies. After: where the VM it replaced went.
        Column {
          id: restoreFace
          visible: root.face === "restore"
          width: parent.width
          spacing: Style.space(14)

          readonly property bool running: service.restoreProc.running
          readonly property bool done: service.restoreDone !== ""
          readonly property bool failed: !running && service.restoreError !== ""
          readonly property bool before: !running && !done && !failed
          readonly property string when: root.restoreEntry
            ? State.whenText(root.restoreEntry.when * 1000, Date.now()) : ""
          // With no VM (after Remove VM) there is nothing to save first: the
          // backup goes back where it was made, with ~/.windows linking there
          // when that was another folder, and the compose is written anew.
          readonly property bool fresh: restoreFace.running || restoreFace.done || restoreFace.failed
            ? service.restoreFresh : root.freshFace
          readonly property string origin: root.restoreEntry ? State.backupOrigin(root.restoreEntry.path) : ""
          readonly property var shape: State.freshShape(root.restoreEntry)

          Text {
            visible: restoreFace.before
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.fg
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: restoreFace.fresh
              ? "Windows comes back as it was on " + restoreFace.when + ", in "
                + State.tildePath(restoreFace.origin, service.home)
                + (restoreFace.origin !== service.home + "/.windows" ? ", with ~/.windows linking there again as before." : ".")
                + " The backup stays."
              : "Windows goes back to how it was on " + restoreFace.when
                + ": files, apps and settings since then are gone from the VM. Nothing is lost for good, because step 1 keeps today's VM as a backup."
          }

          Text {
            visible: restoreFace.before
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: restoreFace.fresh
              ? "1. Copies this backup's disk and login back" + (root.restoreEntry && root.restoreEntry.measured === "btrfs" ? " (instant here)." : ".")
                + "\n2. Asks for your password once, to set the VM up with " + restoreFace.shape.cores + " cores, "
                + restoreFace.shape.ram + " of RAM and its " + (restoreFace.shape.disk || "own") + " disk"
                + (restoreFace.shape.kept ? ", as it had." : " (Install's first offer: Tune changes it after).")
                + "\n3. Its first Start downloads Omarchy's Windows image again, which Remove deleted."
              : "1. Backs up the VM as it is now"
                + (service.backupPlan ? (service.backupPlan.reflink ? " (instant here)."
                  : " (a full copy, " + State.gbText(service.backupPlan.used) + ").") : ".")
                + "\n2. Puts this backup's disk and login back."
                + "\n3. Asks for your password only if the login or the disk size changes."
          }

          // Nothing is replaced with no VM, so nothing to confirm.
          Row {
            visible: restoreFace.before && !restoreFace.fresh
            width: parent.width
            spacing: Style.space(12)

            Text {
              width: parent.width - restoreSwitch.implicitWidth - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.caption
              font.bold: true
              text: (restoreFace.fresh ? "Bring back " : "Go back to ") + restoreFace.when

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.restoreAck = !root.restoreAck
              }
            }

            ToggleSwitch {
              id: restoreSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.restoreAck
              foreground: root.fg
              onToggled: root.restoreAck = !root.restoreAck
            }
          }

          ActionRow {
            id: restoreRow
            visible: restoreFace.before
            cells: 2
            ActionButton {
              width: restoreRow.cellWidth
              iconText: root.closeGlyph
              text: "Cancel"
              allowed: true
              onClicked: root.goBack()
            }
            ActionButton {
              width: restoreRow.cellWidth
              iconText: root.restoreGlyph
              text: "Restore"
              foreground: restoreFace.fresh ? root.fg : root.urgentColor
              primary: restoreFace.fresh
              allowed: (root.restoreAck || restoreFace.fresh) && !!root.restoreEntry && (root.can("start") || root.can("install")) && !service.busy
              onClicked: service.restoreBackup(root.restorePick)
            }
          }

          // ---- restoring
          InfoPair {
            visible: restoreFace.running
            label: service.restoreStep === "safety" ? "Backing up the VM as it is"
              : service.restoreStep === "copy" ? "Putting the backup back"
              : service.restoreStep === "compose" ? "Waiting for your password"
              : service.restoreStep === "swap" ? (service.restoreFresh ? "Putting it in place" : "Swapping the disks")
              : "Starting"
            value: service.restoreStep === "safety" || service.restoreStep === "copy"
              ? State.gbText(service.restoreCopied) : ""
          }

          Text {
            visible: restoreFace.running
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: service.restoreFresh ? "Cancel works while it copies, and leaves things as they were."
              : "Start stays off until it ends. Cancel works while it copies, and leaves the VM as it was."
          }

          ActionRow {
            id: restoreCancelRow
            visible: restoreFace.running
            cells: 1
            ActionButton {
              width: restoreCancelRow.cellWidth
              iconText: root.closeGlyph
              text: "Cancel"
              allowed: service.restoreStep === "safety" || service.restoreStep === "copy"
              onClicked: service.cancelRestore()
            }
          }

          // ---- restored, or not
          Text {
            visible: restoreFace.done || restoreFace.failed
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: restoreFace.failed ? root.urgentColor : root.fg
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: restoreFace.done
              ? "Restored. Windows is back to " + restoreFace.when + ". Start it when you're ready"
                + (service.restoreFresh ? ": the first Start downloads Omarchy's Windows image again, so it takes a little longer." : ".")
              : "Not restored: " + service.restoreError
                + (service.restoreSafety !== "" ? " The safety backup it made stays in the list." : "")
          }

          InfoPair {
            visible: restoreFace.done && service.restoreSafety !== ""
            label: "The VM it replaced"
            value: State.tildePath(service.restoreSafety, service.home)
          }

          ActionRow {
            id: restoreDoneRow
            visible: restoreFace.done || restoreFace.failed
            cells: 1
            ActionButton {
              width: restoreDoneRow.cellWidth
              iconText: root.checkGlyph
              text: "Done"
              allowed: true
              onClicked: { service.clearRestore(); root.openFace("backup") }
            }
          }
        }

        // ============================ Remove ===============================
        // The last thing read before Omarchy's terminal, whose own prompt only
        // asks "Remove Windows VM and delete all associated data?": so the
        // detail is here, with this VM's own disk size and login. Omawin copies
        // nothing; the Shared folder is the one place both sides see and the
        // one thing `remove` keeps, so that is where the backup goes.
        Column {
          visible: root.face === "remove"
          width: parent.width
          spacing: Style.space(14)

          BannerBox {
            accentColor: root.urgentColor
            text: "Back up first. Everything inside Windows is deleted: your files, apps and settings. Keep the whole VM with a backup (Backups…), or copy what you want into the Shared folder, which stays (Start and Connect from the card, then come back)."
          }

          ActionRow {
            id: removeBackupRow
            cells: 1
            ActionButton {
              width: removeBackupRow.cellWidth
              iconText: root.copyGlyph
              text: "Backups…"
              allowed: true
              onClicked: root.openFace("backup")
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoValue { text: "Deleted for good" }
            InfoPair {
              label: "Windows and its disk"
              value: service.currentDisk !== "" ? service.currentDisk : "—"
              note: "~/.windows"
            }
            InfoPair {
              label: "Saved login"
              value: service.loginText
              note: "~/.config/windows"
            }
            InfoPair {
              label: "VM settings and image"
              value: "compose · dockurr/windows"
              dimValue: true
            }
            InfoPair {
              label: "Launcher entry"
              value: "Windows"
              dimValue: true
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoValue { text: "Kept" }
            InfoPair {
              label: "Shared folder"
              value: "~/Windows"
            }
            InfoPair {
              label: "Backups"
              value: "*.bak-<date>, beside the VM's folder"
              dimValue: true
            }
            InfoPair {
              label: "Omawin"
              value: "shows Install… and Restore…"
              dimValue: true
            }
          }

          PanelSeparator { foreground: root.fg }

          Row {
            width: parent.width
            spacing: Style.space(12)

            Text {
              width: parent.width - removeSwitch.implicitWidth - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.caption
              text: "I've copied what I need, or there's nothing to keep."

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeAck = !root.removeAck
              }
            }

            ToggleSwitch {
              id: removeSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.removeAck
              foreground: root.fg
              onToggled: root.removeAck = !root.removeAck
            }
          }

          ActionRow {
            id: removeRow
            cells: 2
            ActionButton {
              width: removeRow.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.can("shared")
              onClicked: service.openShared()
            }
            ActionButton {
              width: removeRow.cellWidth
              iconText: root.trashGlyph
              text: "Remove VM…"
              foreground: root.urgentColor
              allowed: root.removeAck && root.can("remove")
              // The terminal is another window: close first, as Install… does.
              onClicked: { service.removeVm(); root.close() }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            text: "Opens a terminal. Omarchy asks you to confirm (default No), then for your password."
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- the pieces

  // The Windows mark, with the mockup's pause badge overlaid the way
  // TailscaleIcon overlays its warning dot. One component for the bar slot
  // and for the hero; only the size changes.
  component WinMark: Item {
    id: mark
    property real markSize: Style.font.icon
    property color markColor: root.fg
    property bool paused: false

    implicitWidth: glyph.implicitWidth
    implicitHeight: glyph.implicitHeight

    Text {
      id: glyph
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.winGlyph
      color: mark.markColor
      font.family: root.family
      font.pixelSize: mark.markSize
    }

    PauseBadge {
      visible: mark.paused
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: -mark.markSize * 0.18
      anchors.bottomMargin: -mark.markSize * 0.1
      markSize: mark.markSize
      markColor: mark.markColor
    }
  }

  component PauseBadge: Text {
    property real markSize: Style.font.icon
    property color markColor: root.fg

    textFormat: Text.PlainText
    text: root.pauseGlyph
    color: Qt.darker(markColor, 1.4)
    font.family: root.family
    font.pixelSize: Math.max(6, markSize * 0.5)
  }

  // One line of Settings: what it is, its current value and a ›, and below
  // them the one-line tip that says what opening it does. The whole row is
  // the button; its hover wash reaches a little past the text on both sides,
  // so the text stays on the card's left edge like every other face's.
  component SettingsRow: Item {
    id: settingsRow
    property string title: ""
    property string value: ""
    property string tip: ""
    property bool allowed: true
    property bool danger: false
    signal activated()

    width: parent.width
    implicitHeight: rowText.implicitHeight + Style.space(10)
    opacity: allowed ? 1.0 : 0.45

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(6)
      anchors.rightMargin: -Style.space(6)
      radius: Style.cornerRadius
      color: rowArea.containsMouse && settingsRow.allowed
        ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07) : "transparent"
    }

    Column {
      id: rowText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(rowTitle.implicitHeight, rowValue.implicitHeight)

        InfoValue {
          id: rowTitle
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: settingsRow.title
          color: settingsRow.danger ? root.urgentColor : root.fg
        }

        InfoLabel {
          id: rowValue
          anchors.left: rowTitle.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideLeft
          opacity: 0.8
          text: (settingsRow.value !== "" ? settingsRow.value + "  " : "") + "›"
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.dim
        font.family: root.family
        font.pixelSize: Style.font.caption
        text: settingsRow.tip
      }
    }

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: settingsRow.allowed
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: settingsRow.activated()
    }
  }

  // One backup on the Backups face: when it was made and what deleting it
  // frees on the first line; which drive and where on the second. The open
  // one (picked, or the newest) shows its actions; a click opens another.
  component BackupRow: Item {
    id: backupItem
    property var entry: ({})
    property bool open: false
    readonly property bool confirming: backupItem.open && root.backupConfirm === backupItem.entry.path

    width: parent.width
    implicitHeight: backupText.implicitHeight + Style.space(16)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, backupItem.open ? 0.07 : backupArea.containsMouse ? 0.05 : 0.03)
    }

    MouseArea {
      id: backupArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: !backupItem.open
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: { root.backupPick = backupItem.entry.path; root.backupConfirm = "" }
    }

    Column {
      id: backupText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(backupWhen.implicitHeight, backupOwn.implicitHeight)

        InfoValue {
          id: backupWhen
          anchors.left: parent.left
          text: State.whenText(backupItem.entry.when * 1000, Date.now())
        }

        InfoValue {
          id: backupOwn
          anchors.right: parent.right
          text: State.sizeText(backupItem.entry.own)
          opacity: backupItem.entry.own === 0 ? 0.6 : 1.0
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.dim
        font.family: root.family
        font.pixelSize: Style.font.caption
        text: (root.freshFace ? "" : backupItem.entry.same ? "VM's drive · " : "other drive · ")
          + State.tildePath(backupItem.entry.path, service.home)
          + (backupItem.entry.measured === "btrfs" && backupItem.entry.own === 0 ? " · shares all its blocks"
            : backupItem.entry.measured === "du" ? " · a full copy" : "")
      }

      Item { width: 1; height: Style.space(4); visible: backupItem.open }

      ActionRow {
        id: backupActions
        visible: backupItem.open && !backupItem.confirming
        cells: 3
        ActionButton {
          width: backupActions.cellWidth
          iconText: root.restoreGlyph
          text: "Restore…"
          tooltipText: root.stoppedFace || root.freshFace ? "" : "Stop the VM first"
          allowed: (root.stoppedFace || root.freshFace) && !service.busy
          onClicked: { root.restorePick = backupItem.entry.path; root.openFace("restore") }
        }
        ActionButton {
          width: backupActions.cellWidth
          iconText: root.trashGlyph
          text: "Delete…"
          foreground: root.urgentColor
          allowed: !service.backupProc.running && !service.restoreProc.running && service.backupDeleting === ""
          onClicked: root.backupConfirm = backupItem.entry.path
        }
        ActionButton {
          width: backupActions.cellWidth
          iconText: root.folderGlyph
          text: "Show folder"
          allowed: true
          onClicked: { service.openFolder(backupItem.entry.path); root.close() }
        }
      }

      // Delete confirms in place: what goes and what it frees, then the
      // two answers, keeping it first.
      Text {
        visible: backupItem.confirming
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.urgentColor
        font.family: root.family
        font.pixelSize: Style.font.caption
        text: service.backupDeleting === backupItem.entry.path ? "Deleting…"
          : "Delete this backup? " + (backupItem.entry.own > 0
            ? "It frees " + State.sizeText(backupItem.entry.own) + ". " : "")
            + "It can't be undone."
      }

      ActionRow {
        id: backupConfirmRow
        visible: backupItem.confirming
        cells: 2
        ActionButton {
          width: backupConfirmRow.cellWidth
          iconText: root.backGlyph
          text: "Keep it"
          allowed: service.backupDeleting === ""
          onClicked: root.backupConfirm = ""
        }
        ActionButton {
          width: backupConfirmRow.cellWidth
          iconText: root.trashGlyph
          text: "Delete"
          foreground: root.urgentColor
          allowed: service.backupDeleting === "" && !service.backupProc.running && !service.restoreProc.running
          onClicked: service.deleteBackup(backupItem.entry.path)
        }
      }
    }
  }

  // A row of equal-width buttons, the Display panel's scale-pill geometry.
  // Three cells on the ready and booting cards, two everywhere else.
  component ActionRow: Row {
    property int cells: 1
    readonly property real cellWidth: cells > 0 ? (width - spacing * (cells - 1)) / cells : 0

    width: parent.width
    spacing: Style.space(6)
  }

  // Button has no disabled paint of its own, so a dead button is the kit's
  // bordered button at the mockup's 0.45 opacity with its input off.
  component ActionButton: Button {
    property bool allowed: false
    // The one action the state is for (Start, Connect, Resume, Install…):
    // the kit's selected paint, the accent-tinted fill its segmented
    // controls give the chosen option, so it reads first in every theme.
    property bool primary: false

    selected: primary && allowed
    bordered: true
    fontSize: Style.font.caption
    iconSize: Style.font.bodySmall
    verticalPadding: Style.spacing.controlPaddingY
    horizontalPadding: Style.spacing.sm
    foreground: root.fg
    fontFamily: root.family
    enabled: allowed
    opacity: allowed ? 1.0 : 0.45
  }

  // The Power panel's info pairs, with two additions: `dimValue` for the
  // readings the mockup greys out ("—", a reading that is merely absent rather
  // than bad) and `note` for the dim aside beside a value — the Disk pair's
  // "from 64G" while a bigger size is waiting for the next start.
  component InfoPair: Row {
    id: pair
    property string label: ""
    property string value: ""
    property string note: ""
    property bool dimValue: false
    property bool urgent: false

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { id: pairLabel; text: pair.label; color: pair.urgent ? root.urgentColor : root.fg }
    Item {
      width: Math.max(0, pair.width - pairLabel.implicitWidth - pairValue.implicitWidth
        - (pairNote.visible ? pairNote.implicitWidth + pair.spacing : 0) - pair.spacing * 2)
      height: 1
    }
    InfoValue {
      id: pairValue
      text: pair.value
      color: pair.urgent ? root.urgentColor : root.fg
      opacity: pair.dimValue ? 0.6 : 1.0
    }
    InfoLabel { id: pairNote; text: pair.note; visible: pair.note !== "" }
  }

  // A control's label line: what it is on the left, what bounds it on the
  // right ("of 8 on this machine", "grows only · 412 GB free").
  component FieldHeader: Item {
    id: field
    property string label: ""
    property string hint: ""

    width: parent.width
    implicitHeight: Math.max(fieldLabel.implicitHeight, fieldHint.implicitHeight)

    InfoValue {
      id: fieldLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      opacity: 0.6
      text: field.label
    }

    InfoLabel {
      id: fieldHint
      anchors.left: fieldLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      text: field.hint
    }
  }

  // The failure block's geometry, as a component: a faint wash, a 2px rule down
  // the leading edge in the banner's colour, and one wrapped line of text. Used
  // for what Tune and Update password answer with.
  component BannerBox: Item {
    id: banner
    property string text: ""
    property color accentColor: root.fg
    // A × at the right, for a banner that stays until it is put away.
    property bool dismissible: false
    signal dismissed()

    width: parent.width
    implicitHeight: bannerText.implicitHeight + Style.space(12)

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(banner.accentColor.r, banner.accentColor.g, banner.accentColor.b, 0.06)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Math.max(1, Style.space(2))
      color: banner.accentColor
    }

    Text {
      id: bannerText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: banner.dismissible ? bannerClose.left : parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: banner.text
      color: root.fg
      font.family: root.family
      font.pixelSize: Style.font.caption
    }

    // The same square, borderless-at-rest control as Back, top right.
    Button {
      id: bannerClose
      visible: banner.dismissible
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      iconText: root.closeGlyph
      iconSize: Style.font.caption
      fontSize: Style.font.caption
      verticalPadding: Style.space(4)
      horizontalPadding: Style.space(4)
      foreground: root.fg
      fontFamily: root.family
      tooltipText: "Dismiss"
      implicitWidth: implicitHeight
      onClicked: banner.dismissed()
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.family
    font.pixelSize: Style.font.caption
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
