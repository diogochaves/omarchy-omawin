import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar glyph and the popup card of chaves.omawin, and nothing else: every
// decision here is a read of `service.state` or `service.actions`, every
// button calls a Service method, and no Process is started from this file.
// Service.qml next door owns the samplers, the timers and the actions.
//
// The card is the one in plans/omawin-mockup.html, eight faces of the same
// column: hero, an indeterminate progress bar while a transient is pending, a
// caption line or two columns of info pairs depending on the state, the
// failure block, and one or two rows of equal-width buttons. Which of those
// are visible is the only thing that changes between states — the layout,
// the paddings and the type sizes are the shell's own tokens throughout, so
// the card re-skins with the theme exactly like the first-party panels.
Panel {
  id: root
  moduleName: "chaves.omawin"
  ipcTarget: "chaves.omawin"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for status() and the fail() debug method below.
  manageIpc: false

  Service { id: service }

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
  readonly property string face: root.failed ? service.base : root.vmState
  readonly property bool inTransit: vmState === "starting" || vmState === "stopping"
  readonly property bool pulsing: root.inTransit || vmState === "booting"

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
  property real pulsePhase: 1.0
  SequentialAnimation on pulsePhase {
    running: root.pulsing
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 0.45; duration: 800; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.45; to: 1.0; duration: 800; easing.type: Easing.InOutSine }
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

  // A button is live only when the state machine allows it AND no action is
  // already in flight.
  function can(name) {
    return !service.busy && !!service.actions[name]
  }

  // Pause, Resume, Web viewer and Shared folder are drawn from phase 2 but
  // wired in phase 4; until then they are visible and dead, so the card keeps
  // the mockup's shape instead of reflowing when they arrive.
  readonly property bool phase4: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    service.panelOpen = opened
    if (opened) service.refresh()
  }

  // ----------------------------------------------------------------- the IPC

  IpcHandler {
    target: "chaves.omawin"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // The headless check: the painted state plus the sampler line it came
    // from, e.g. "stopped installed=1 docker=active pid= frozen= …".
    function status(): string { return service.state + " " + service.sampleLine }
    // Debug only: stand a sampler line (an RDP verdict, "ok" or "no", and a
    // pending transient, "start" or "stop") in for the real ones, so every
    // face of the card can be looked at with the VM switched off. An empty
    // line hands the widget back to the sampler. See the IPC table in the
    // README.
    function mock(line: string, probe: string, action: string): string {
      service.mockLine = String(line)
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
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · Windows VM / STATUS · cores·RAM pill ----------
        // PanelHero has no per-line colour, so the whole hero goes urgent on
        // the failed card rather than only its status line. The alternative
        // was reimplementing the hero, which the kit asks us not to do.
        PanelHero {
          title: "Windows VM"
          meta: service.label
          detail: service.detail
          foreground: root.failed ? root.urgentColor : root.fg
          fontFamily: root.family
          iconOpacity: root.vmState === "not-installed" ? 0.45 : 1.0
          iconComponent: Component {
            WinMark {
              markSize: Style.font.display
              markColor: root.glyphColor
              paused: root.vmState === "paused"
              opacity: root.pulsing ? root.pulsePhase : 1.0
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
          visible: root.inTransit || root.vmState === "booting"
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

            NumberAnimation on x {
              running: progress.visible
              loops: Animation.Infinite
              duration: 1800
              easing.type: Easing.InOutCubic
              from: root.vmState === "stopping" ? progressTrack.width : -progressFill.width
              to: root.vmState === "stopping" ? -progressFill.width : progressTrack.width
            }
          }
        }

        // ---------- The one-paragraph states ----------
        Text {
          width: parent.width
          visible: text !== ""
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
          visible: root.vmState === "stopped" || root.vmState === "booting" || root.vmState === "ready"
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap

            InfoPair {
              visible: root.vmState === "stopped"
              label: "Cores"
              value: service.sample.cores ? String(service.sample.cores) : "—"
              dimValue: !service.sample.cores
            }
            InfoPair {
              visible: root.vmState === "stopped"
              label: "RAM"
              value: service.sample.ram ? service.sample.ram : "—"
              dimValue: !service.sample.ram
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
              value: "—"
              dimValue: true
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
            InfoPair {
              visible: root.vmState === "stopped"
              label: "Last run"
              value: "—"
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
          visible: root.failed && service.failedMessage !== ""
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

        // ---------- Actions ----------
        PanelSeparator {
          visible: root.vmState !== "not-installed" && !root.inTransit
          foreground: root.fg
        }

        PanelSectionHeader {
          visible: root.vmState === "ready"
          text: "ACTIONS"
          foreground: root.fg
          fontFamily: root.family
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          // not-installed
          ActionRow {
            id: installRow
            visible: root.face === "not-installed"
            cells: 1
            ActionButton {
              width: installRow.cellWidth
              iconText: root.termGlyph
              text: "Install…"
              allowed: root.can("install")
              onClicked: service.install()
            }
          }

          // stopped (and the failed card that sits on top of it)
          ActionRow {
            id: stoppedRow
            visible: root.face === "stopped"
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
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.phase4 && root.can("shared")
              onClicked: service.openShared()
            }
          }

          // starting / stopping — everything but the folder is dead
          ActionRow {
            id: transientRow
            visible: root.face === "starting" || root.face === "stopping"
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
              allowed: root.phase4 && root.can("web")
              onClicked: service.openWeb()
            }
          }

          ActionRow {
            id: transientRow2
            visible: transientRow.visible
            cells: 1
            ActionButton {
              width: transientRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.phase4 && root.can("shared")
              onClicked: service.openShared()
            }
          }

          // booting
          ActionRow {
            id: bootingRow
            visible: root.face === "booting"
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

          // ready — the only three-button row in the kit
          ActionRow {
            id: readyRow
            visible: root.face === "ready"
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
              allowed: root.phase4 && root.can("pause")
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
            visible: root.face === "paused"
            cells: 2
            ActionButton {
              width: pausedRow.cellWidth
              iconText: root.playGlyph
              text: "Resume"
              allowed: root.phase4 && root.can("resume")
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
            cells: 1
            ActionButton {
              width: pausedRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.phase4 && root.can("shared")
              onClicked: service.openShared()
            }
          }

          // booting and ready share the second row
          ActionRow {
            id: liveRow2
            visible: bootingRow.visible || readyRow.visible
            cells: 2
            ActionButton {
              width: liveRow2.cellWidth
              iconText: root.globeGlyph
              text: "Web viewer"
              allowed: root.phase4 && root.can("web")
              onClicked: service.openWeb()
            }
            ActionButton {
              width: liveRow2.cellWidth
              iconText: root.folderGlyph
              text: "Shared folder"
              allowed: root.phase4 && root.can("shared")
              onClicked: service.openShared()
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

  // A row of equal-width buttons, the Display panel's scale-pill geometry.
  // Never more than two cells except on the ready card.
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

  // The Power panel's info pairs, with one addition: `dimValue` for the
  // readings the mockup greys out ("—", the phase 4 placeholders, a reading
  // that is merely absent rather than bad).
  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property bool dimValue: false

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    InfoValue { text: value; opacity: dimValue ? 0.6 : 1.0 }
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
