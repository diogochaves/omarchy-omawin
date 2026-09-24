import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/State.js" as State

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
// On top of those eight states there are four sub-faces, `face`: Tune (the
// VM's shape), Login (the stored RDP credentials), Update password and
// Settings (the optional polkit rule). Each replaces the body of the same card
// and comes back with the ‹ at the top left (or Esc); the gear in the hero opens Settings from anywhere.
// The state machine keeps running underneath, so Tune and Update password —
// the two that rewrite the compose, which is only read at the next start —
// close themselves the moment the VM stops being stopped.
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
    onPasswordSaved: root.face = "login"
  }

  // ------------------------------------------------------------ the palette
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.4)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- the state
  readonly property string vmState: service.state
  readonly property bool failed: vmState === "failed"
  // "failed" paints the buttons of the state underneath it so the user can
  // retry, which is exactly what State.allowedActions does with `base`.
  readonly property string stateFace: root.failed ? service.base : root.vmState
  readonly property bool inTransit: vmState === "starting" || vmState === "stopping"
  readonly property bool pulsing: root.inTransit || vmState === "booting"

  // Which body the card is showing: the state machine's own ("live") or one of
  // the four sub-faces. Everything the live card draws is gated on `live`.
  property string face: "live"
  readonly property bool live: root.face === "live"
  // Whether the VM is off as far as the sampler is concerned — on the failed
  // card that is the state underneath. The compose can only be rewritten here,
  // so it gates Tune, Update password and both of their faces.
  readonly property bool stoppedFace: root.stateFace === "stopped"

  // Keep this in step with manifest.json: it is only ever printed, on the
  // Settings pill.
  readonly property string pluginVersion: "0.2.0"

  // The path the Settings face runs `sudo … setup polkit` on, resolved from
  // this file's own location like everything else in the Service.
  readonly property string ruleUserName: service.ruleUser !== "" ? service.ruleUser : service.user

  // The glyph's colour per the mockup's "Bar glyph per state" row: dimmed
  // with nothing installed, the dim foreground when the VM is off or going
  // off, full foreground while it is alive, urgent when something failed
  // (`bar.urgent`, the colour the Updates widget uses).
  readonly property color glyphColor: {
    if (root.failed) return root.urgentColor
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
  readonly property string closeGlyph: ""
  readonly property string minusGlyph: ""
  readonly property string plusGlyph: ""

  // The hero's glyph: the Windows mark on the live card, the face's own glyph
  // on a sub-face. Two components rather than one with a branch inside, so the
  // mark keeps its pause badge and its pulse and the glyph stays a plain Text.
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

  // On a sub-face that slot is Back: top left, where apps put it, and the
  // one way out of every sub-face (Esc does the same, see goBack()).
  readonly property Component backHero: Component {
    Button {
      bordered: true
      iconText: root.backGlyph
      iconSize: Style.font.bodySmall
      fontSize: Style.font.caption
      verticalPadding: Style.spacing.controlPaddingY
      horizontalPadding: Style.spacing.sm
      foreground: root.fg
      fontFamily: root.family
      tooltipText: "Back · Esc"
      // Square: as wide as it is tall, the chevron centred by the kit's row.
      implicitWidth: implicitHeight
      enabled: !service.busy
      opacity: enabled ? 1.0 : 0.45
      onClicked: root.goBack()
    }
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

  // The installer's own RAM list (2-64G), and its disk list with 96G added —
  // the step between 64 and 128 the mockup offers, since growing a disk by a
  // little is a more common wish here than doubling it. Both are filtered
  // against the host in the Tune face below.
  readonly property var ramSizes: [2, 4, 8, 16, 32, 64]
  readonly property var diskSizes: [32, 64, 96, 128, 256, 512]

  function resetTune() {
    var cores = parseInt(service.coresText, 10)
    root.tuneCores = cores > 0 ? cores : 2
    root.tuneRam = State.RAM_SHAPE.test(service.ramText) ? service.ramText : "4G"
    root.tuneDisk = service.diskText !== "—" ? service.diskText : ""
  }

  // What the RAM chips offer: the wizard's own list, cut off at what the
  // machine has, plus whatever the VM is set to now — a machine that lost RAM
  // since must still be able to show (and keep) the size in the compose.
  readonly property var ramChoices: {
    var list = []
    for (var i = 0; i < root.ramSizes.length; i++) {
      if (service.hostRamGb <= 0 || root.ramSizes[i] <= service.hostRamGb)
        list.push(root.ramSizes[i])
    }
    var now = parseInt(root.tuneRam, 10)
    if (now > 0 && list.indexOf(now) === -1) {
      list.push(now)
      list.sort(function (a, b) { return a - b })
    }
    return list
  }

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
  // image already on disk is not subtracted.
  readonly property int diskNeedGb: (parseInt(root.tuneDisk, 10) || 0) + 10
  readonly property bool tuneRoom: service.freeGb < 0 || root.diskNeedGb <= service.freeGb
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
    return text
  }

  // Save needs a password, a known shape to carry through the writer and a VM
  // that is off, for the same reason Apply does.
  readonly property bool canSave: !service.busy && root.stoppedFace
    && service.canSavePassword && newPassword.text !== "" && newPassword.text.length <= 64

  // Where Back leads from the Login face: the card, or Settings when Login
  // was opened from its "view →" line.
  property string loginFrom: "live"

  // One step back: Update password to Login, Login to wherever it was opened
  // from, every other sub-face to the card. On the card itself it closes it.
  function goBack() {
    if (root.face === "live") root.close()
    else if (root.face === "updatePassword") root.openFace("login")
    else if (root.face === "login") root.openFace(root.loginFrom)
    else root.openFace("live")
  }

  function openFace(name) {
    if (name === "login" && root.face !== "updatePassword")
      root.loginFrom = root.face === "settings" ? "settings" : "live"
    if (name === "tune") {
      service.clearNotice()
      service.readLimits()
      root.resetTune()
    }
    if (name === "settings") service.readRule()
    if (name === "updatePassword") {
      service.clearNotice()
      newPassword.text = ""
      newPassword.password = true
      // The field is the only thing on that face to do: give it the keyboard,
      // which is also what unblocks the panel's key catcher for typing.
      newPassword.forceActiveFocus()
    } else {
      keyCatcher.forceActiveFocus()
    }
    // Nothing keeps a revealed password across a face change.
    service.maskPassword()
    root.face = name
  }

  // The two faces that rewrite the compose only exist while the VM is off: the
  // write is consumed by the next `docker compose up`, and a VM that started
  // underneath would recreate its container from a file the user is still
  // editing. They close themselves rather than fail on Apply.
  onVmStateChanged: {
    if (!root.stoppedFace && (root.face === "tune" || root.face === "updatePassword"))
      root.face = "live"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    service.panelOpen = opened
    if (opened) {
      service.refresh()
      // The polkit rule can have been installed or removed from a terminal
      // since the card was last open, so the switch is re-read every time.
      service.readRule()
    } else {
      // A closed card keeps nothing: back to the live face, and the revealed
      // password is dropped rather than waiting out its 15 s.
      root.face = "live"
      service.maskPassword()
    }
  }

  // ----------------------------------------------------------------- the IPC

  IpcHandler {
    target: "chaves.omawin"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // The headless check: the painted state, the sampler line it came from
    // and the bar tooltip, e.g. "stopped installed=1 docker=active pid= … |
    // Windows VM · STOPPED · 4 cores · 16G".
    function status(): string {
      return service.state + " " + service.sampleLine + " | " + service.tooltip
    }
    // Debug only: stand a sampler line (an RDP verdict, "ok" or "no", and a
    // pending transient, "start" or "stop") in for the real ones, so every
    // face of the card can be looked at with the VM switched off. An empty
    // line hands the widget back to the sampler. See the IPC table in the
    // README.
    function mock(line: string, probe: string, action: string): string {
      service.mockLine = String(line).slice(0, 512)
      service.mockProbe = String(probe)
      // Handing back to the sampler also drops the mocked transient, so the
      // card does not sit in "starting" for 150 s after `mock "" "" ""`.
      if (String(line) === "") service.clearDesired()
      service.refresh()
      if (String(action) !== "") service.setDesired(String(action))
      return service.state + " " + service.sampleLine
    }
    // Debug only: paint the failed card without breaking a VM to get there.
    // Cleared by the next successful action or state change, like any other
    // failure — or at once by calling it with an empty string. See the IPC
    // table in the README.
    function fail(text: string): string {
      if (String(text).replace(/^\s+|\s+$/g, "") === "") service.clearDesired()
      else service.fail(text)
      return service.state + " " + service.failedMessage
    }
    // Debug only: show one of the card's faces — live, tune, login,
    // updatePassword or settings — without pressing through to it, the way
    // `mock` reaches every state. It goes through the same openFace() the
    // buttons use, so the face is seeded the way a press would seed it; the
    // two faces that rewrite the compose still close themselves when the VM
    // is not stopped, and nothing runs. Anything else means "live".
    function face(name: string): string {
      var faces = ["live", "tune", "login", "updatePassword", "settings"]
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
    iconComponent: Component {
      Item {
        WinMark {
          anchors.centerIn: parent
          markSize: Style.bar.iconFont
          markColor: root.glyphColor
          paused: root.vmState === "paused"
          opacity: root.glyphOpacity * (root.pulsing ? root.pulsePhase : 1.0)
        }
      }
    }
    // Left opens the card; middle is the one-click shortcut from the mockup's
    // interaction table (Start when stopped, Connect when ready, nothing
    // anywhere else — never a destructive action on a single click); right
    // does nothing.
    onPressed: function (code) {
      if (code === Qt.MiddleButton) {
        if (root.can("start")) service.start()
        else if (root.can("connect")) service.connect()
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
      root.failed ? root.urgentColor : Color.popups.border,
      Color.popups.border, Math.max(1, Style.space(2)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The kit's own instruction for a panel with an inline editor: this
      // handler takes keys BEFORE any descendant, so without `blocked` every
      // character typed into the password field would be eaten as a shortcut.
      blocked: newPassword.activeFocus
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

        // ---------- Hero: glyph · Windows VM / STATUS · shape pill · gear -------
        // PanelHero has no per-line colour, so the whole hero goes urgent on
        // the failed card rather than only its status line. The alternative
        // was reimplementing the hero, which the kit asks us not to do.
        //
        // The sub-faces reuse it as they are: their own title, their own glyph
        // where the Windows mark was, the pill for whatever they have to show
        // there. The gear rides the hero's own trailing slot and is the way
        // into Settings from every live face.
        PanelHero {
          title: root.live ? "Windows VM"
            : root.face === "tune" ? "Tune"
            : root.face === "login" ? "Login"
            : root.face === "updatePassword" ? "Update password"
            : "Settings"
          meta: root.live ? service.label
            : root.face === "login" ? "Windows VM · RDP and web viewer"
            : root.face === "settings" ? "Windows VM"
            : "Windows VM · " + service.label.toLowerCase()
          detail: root.live || root.face === "tune" ? service.detail
            : root.face === "settings" ? "chaves.omawin " + root.pluginVersion
            : ""
          foreground: root.failed && root.live ? root.urgentColor : root.fg
          fontFamily: root.family
          iconOpacity: root.vmState === "not-installed" && root.live ? 0.45 : 1.0
          iconComponent: root.live ? winHero : backHero
          trailingControl: Component {
            Button {
              visible: root.live
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
          visible: root.live && (root.inTransit || root.vmState === "booting")
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
            color: root.vmState === "stopping" ? root.dim : Color.accent

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
          color: root.dim
          font.family: root.family
          font.pixelSize: Style.font.caption
          text: {
            if (root.vmState === "not-installed")
              return "No Windows VM on this machine. The installer asks for RAM, cores, disk size and a login, then downloads Windows 11 (10–15 min). It runs in a floating terminal."
            if (root.vmState === "starting")
              return "Bringing the container up. Omarchy may ask for authorisation."
            if (root.vmState === "booting" && service.stopHeldByLauncher)
              return "The launcher holds the VM while Windows boots; Stop unlocks once it answers on RDP."
            if (root.vmState === "paused")
              return "Frozen in memory. Resume picks up where it left off; the guest clock resyncs from the host."
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
            // same values the hero's pill shows through service.detail.
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
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap

            InfoPair {
              visible: root.vmState === "stopped"
              label: "Docker"
              value: service.sample.docker !== "" ? service.sample.docker : "—"
              dimValue: !service.dockerActive
            }
            // The disk is the apparent size of ~/.windows/data.img. After a
            // Tune that grows it, the note keeps the size it still has beside
            // the size the next start will make it.
            InfoPair {
              visible: root.vmState === "stopped"
              label: "Disk"
              value: service.diskText
              note: service.diskNote
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
        // rewrite changed nothing about the VM.
        BannerBox {
          visible: service.noticeText !== "" && root.face !== "settings"
          text: service.noticeText
          accentColor: service.noticeOk ? Color.accent : root.urgentColor
        }

        // After a start that grew the disk: Windows leaves the new space
        // unallocated, and this is the moment it matters. Until × or a stop.
        BannerBox {
          visible: service.grewNote !== "" && root.live
          text: service.grewNote
          accentColor: Color.accent
          dismissible: true
          onDismissed: service.dismissGrew()
        }

        // ---------- Actions ----------
        PanelSeparator {
          visible: root.live && root.vmState !== "not-installed" && !root.inTransit
          foreground: root.fg
        }

        PanelSectionHeader {
          visible: root.live && root.vmState === "ready"
          text: "ACTIONS"
          foreground: root.fg
          fontFamily: root.family
        }

        Column {
          id: liveActions
          visible: root.live
          width: parent.width
          spacing: Style.space(6)

          // not-installed
          ActionRow {
            id: installRow
            visible: root.stateFace === "not-installed"
            cells: 1
            ActionButton {
              width: installRow.cellWidth
              iconText: root.termGlyph
              text: "Install…"
              allowed: root.can("install")
              // The terminal is another window; while this popup holds keyboard focus
              // Hyprland will not hand it over, so close first (as the network panel does).
              onClicked: { service.install(); root.close() }
            }
          }

          // stopped (and the failed card that sits on top of it). Tune is
          // offered here and nowhere else: the compose it writes is read at the
          // next `docker compose up`.
          ActionRow {
            id: stoppedRow
            visible: root.stateFace === "stopped"
            cells: 2
            ActionButton {
              width: stoppedRow.cellWidth
              iconText: root.playGlyph
              text: "Start"
              allowed: root.can("start")
              onClicked: service.start()
            }
            ActionButton {
              width: stoppedRow.cellWidth
              iconText: root.tuneGlyph
              text: "Tune…"
              allowed: root.can("tune")
              onClicked: root.openFace("tune")
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
            LoginButton { width: stoppedRow2.cellWidth }
          }

          // starting / stopping — everything but the folder is dead
          ActionRow {
            id: transientRow
            visible: root.stateFace === "starting" || root.stateFace === "stopping"
            cells: 2
            ActionButton {
              width: transientRow.cellWidth
              iconText: root.playGlyph
              text: "Start"
              allowed: root.can("start")
              onClicked: service.start()
            }
            ActionButton {
              width: transientRow.cellWidth
              iconText: root.globeGlyph
              text: "Web viewer"
              allowed: root.can("web")
              onClicked: service.openWeb()
            }
          }

          ActionRow {
            id: transientRow2
            visible: transientRow.visible
            cells: 2
            ActionButton {
              width: transientRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.can("shared")
              onClicked: service.openShared()
            }
            LoginButton { width: transientRow2.cellWidth }
          }

          // booting
          ActionRow {
            id: bootingRow
            visible: root.stateFace === "booting"
            cells: 2
            ActionButton {
              width: bootingRow.cellWidth
              iconText: root.linkGlyph
              text: "Connect"
              allowed: root.can("connect")
              onClicked: service.connect()
            }
            ActionButton {
              width: bootingRow.cellWidth
              iconText: root.stopGlyph
              text: "Stop"
              allowed: root.can("stop")
              onClicked: service.stop()
            }
          }

          // ready: Connect, Pause and Stop; its second row is shared with booting
          ActionRow {
            id: readyRow
            visible: root.stateFace === "ready"
            cells: 3
            ActionButton {
              width: readyRow.cellWidth
              iconText: root.linkGlyph
              text: "Connect"
              allowed: root.can("connect")
              onClicked: service.connect()
            }
            ActionButton {
              width: readyRow.cellWidth
              iconText: root.pauseGlyph
              text: "Pause"
              allowed: root.can("pause")
              onClicked: service.pause()
            }
            ActionButton {
              width: readyRow.cellWidth
              iconText: root.stopGlyph
              text: "Stop"
              allowed: root.can("stop")
              onClicked: service.stop()
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

          ActionRow {
            id: pausedRow2
            visible: pausedRow.visible
            cells: 2
            ActionButton {
              width: pausedRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.can("shared")
              onClicked: service.openShared()
            }
            LoginButton { width: pausedRow2.cellWidth }
          }

          // booting and ready share the second row
          ActionRow {
            id: liveRow2
            visible: bootingRow.visible || readyRow.visible
            cells: 3
            ActionButton {
              width: liveRow2.cellWidth
              iconText: root.globeGlyph
              text: "Web viewer"
              allowed: root.can("web")
              onClicked: service.openWeb()
            }
            ActionButton {
              width: liveRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.can("shared")
              onClicked: service.openShared()
            }
            LoginButton { width: liveRow2.cellWidth }
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

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader {
              label: "Cores"
              hint: service.hostCores > 0 ? "of " + service.hostCores + " on this machine" : ""
            }

            Row {
              spacing: Style.space(6)

              ActionButton {
                iconText: root.minusGlyph
                allowed: !service.busy && root.tuneCores > 1
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
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader {
              label: "RAM"
              hint: service.hostRamGb > 0
                ? "of " + service.hostRamGb + "G · guest only, no balloon"
                : "guest only, no balloon"
            }

            // The wizard's own list, cut off at what the machine has.
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
              ? "Changed the password inside Windows? Save the new one here so Connect keeps working."
              : "Changed the password inside Windows? Stop the VM first: saving it here also rewrites the compose, which is only read at the next start."
          }

          ActionRow {
            id: loginRow2
            cells: 1
            ActionButton {
              width: loginRow2.cellWidth
              iconText: root.keyGlyph
              text: "Update password…"
              allowed: !service.busy && root.stoppedFace
              onClicked: root.openFace("updatePassword")
            }
          }
        }

        // ======================= Update password ===========================
        // Only what this machine sends when it connects. The account itself is
        // changed inside Windows; this is where the new password is written
        // down afterwards, into the credentials file and into the compose's
        // fallback copy of it — one authorisation, stopped only.
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
            text: "Type the password Windows now has for " + service.loginText
              + ". It only changes what this machine sends when connecting; it cannot change the account itself."
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            FieldHeader { label: "New password"; hint: "printable, up to 64 chars" }

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
                onAccepted: if (root.canSave) service.savePassword(text)
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
              ? "To change the account's password: open the Web viewer (the console signs in by itself), Settings › Accounts › Sign-in options, then come back here."
              : "The VM's shape is not known yet, and the compose cannot be rewritten without it. Start the VM once, then come back."
          }

          ActionRow {
            id: updateRow
            cells: 1
            ActionButton {
              width: updateRow.cellWidth
              iconText: root.checkGlyph
              text: "Save…"
              allowed: root.canSave
              onClicked: service.savePassword(newPassword.text)
            }
          }
        }

        // =========================== Settings ==============================
        // The one opt-in: a polkit rule that makes Start, Stop, Pause and
        // Resume promptless for this user. It needs root, so the work happens
        // in Omarchy's floating terminal running this plugin's own `setup`,
        // which prints the rule in full and asks before writing it. The switch
        // is a picture of the user-owned copy setup leaves behind — the rules
        // directory itself cannot be read from here at all.
        Column {
          visible: root.face === "settings"
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
                text: service.rulePresent
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

          // The five command lines, rendered from the same template `setup`
          // installs, so what is read here is what the terminal will show.
          Item {
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
              text: "Allows, for " + root.ruleUserName + " only, exactly:\n"
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
              ? "Start, Stop, Pause and Resume run without a dialog. Tune's Apply and Update password still ask: rewriting the VM's configuration stays behind authorisation on purpose, and it is rare."
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

          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            Item {
              width: parent.width
              implicitHeight: settingsLogin.implicitHeight

              InfoPair {
                id: settingsLogin
                label: "Login"
                value: service.loginText
                note: service.loginText !== "—" ? "view →" : ""
                dimValue: true
              }

              MouseArea {
                anchors.fill: parent
                enabled: service.loginText !== "—"
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openFace("login")
              }
            }

            InfoPair {
              label: "Helper"
              value: "/usr/bin/omarchy-windows-vm"
              dimValue: true
            }
            InfoPair {
              label: "Compose"
              value: "/var/lib/omarchy/windows"
              dimValue: true
            }
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

    Text {
      visible: mark.paused
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: -mark.markSize * 0.18
      anchors.bottomMargin: -mark.markSize * 0.1
      textFormat: Text.PlainText
      text: root.pauseGlyph
      color: Qt.darker(mark.markColor, 1.4)
      font.family: root.family
      font.pixelSize: Math.max(6, mark.markSize * 0.5)
    }
  }

  // The way into the Login face, always the last button of a card's bottom
  // row: the web viewer asks for this login while the VM boots or runs, so it
  // has to be reachable from every state, not only the stopped one. It only
  // opens a face and reads a file the user owns, so `busy` does not grey it.
  component LoginButton: ActionButton {
    iconText: root.keyGlyph
    text: "Login…"
    allowed: service.loginText !== "—"
    onClicked: root.openFace("login")
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

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { id: pairLabel; text: pair.label }
    Item {
      width: Math.max(0, pair.width - pairLabel.implicitWidth - pairValue.implicitWidth
        - (pairNote.visible ? pairNote.implicitWidth + pair.spacing : 0) - pair.spacing * 2)
      height: 1
    }
    InfoValue { id: pairValue; text: pair.value; opacity: pair.dimValue ? 0.6 : 1.0 }
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
