import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// WireGuard tunnels in the Omarchy bar. Left click opens the tunnel list,
// right click toggles the primary tunnel without opening anything.
//
// Two different privilege paths, deliberately: the status poll runs every few
// seconds and uses `ip link`, which needs no privileges at all, while only the
// (rare) config listing and the actual up/down calls go through sudo. That
// keeps a password prompt off the hot path entirely.
Panel {
  id: root
  moduleName: "wcoppens.wireguard"
  ipcTarget: "wcoppens.wireguard"
  manageIpc: false

  property var configs: []
  property var liveInterfaces: []
  property bool configsReadable: true
  property string lastError: ""
  property string pendingName: ""
  property bool pendingUp: false
  property bool busy: false
  property int tunnelIndex: 0
  property bool cursorActive: false

  readonly property int refreshIntervalSec: Math.max(1, setting("refreshIntervalSec", 5))
  readonly property bool exclusive: setting("exclusive", true) === true
  readonly property string defaultTunnel: String(setting("defaultTunnel", ""))

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // While a wg-quick call is in flight the model reports the *requested* state,
  // so the switch throws on click instead of a poll interval later. Exclusive
  // mode drops the others in the same breath, matching what the script does.
  readonly property var tunnels: {
    var list = Model.buildTunnels(configs, liveInterfaces)
    if (!busy || pendingName === "") return list
    var out = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (item.name === pendingName) out.push({ name: item.name, up: pendingUp })
      else if (pendingUp && exclusive) out.push({ name: item.name, up: false })
      else out.push(item)
    }
    return out
  }

  readonly property var activeNames: Model.upNames(tunnels)
  readonly property bool anyUp: activeNames.length > 0
  readonly property string summary: Model.statusSummary(tunnels)

  // Right click and the hero switch act on one tunnel: whatever is currently up,
  // else the pinned `defaultTunnel`, else the first one configured.
  readonly property string primaryTunnel: {
    if (activeNames.length > 0) return activeNames[0]
    if (defaultTunnel !== "") return defaultTunnel
    return tunnels.length > 0 ? tunnels[0].name : ""
  }

  function refreshState() {
    if (!stateProc.running) stateProc.running = true
  }

  function refreshConfigs() {
    if (!listProc.running) listProc.running = true
  }

  function refresh() {
    refreshConfigs()
    refreshState()
  }

  function setTunnel(name, turnOn) {
    if (busy || String(name) === "") return
    lastError = ""
    pendingName = String(name)
    pendingUp = turnOn === true
    busy = true
    toggleProc.command = ["sh", "-c", Model.toggleScript(pendingName, pendingUp, exclusive, activeNames)]
    toggleProc.running = true
  }

  function toggleTunnel(name) {
    var list = tunnels
    for (var i = 0; i < list.length; i++) {
      if (list[i].name === name) {
        setTunnel(name, !list[i].up)
        return
      }
    }
    setTunnel(name, true)
  }

  function togglePrimary() {
    if (primaryTunnel !== "") toggleTunnel(primaryTunnel)
  }

  function ensureCursor() {
    if (tunnels.length === 0) { tunnelIndex = 0; return }
    if (tunnelIndex >= tunnels.length) tunnelIndex = tunnels.length - 1
    if (tunnelIndex < 0) tunnelIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0 || tunnels.length === 0) return
    tunnelIndex = Math.max(0, Math.min(tunnels.length - 1, tunnelIndex + dy))
  }

  function activateCursor() {
    ensureCursor()
    if (tunnels.length === 0) return
    toggleTunnel(tunnels[tunnelIndex].name)
  }

  function setTunnelCursor(index) {
    cursorActive = true
    tunnelIndex = index
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refresh()

  Process {
    id: listProc
    command: ["sudo", "-n", "/usr/bin/find", "/etc/wireguard", "-maxdepth", "1", "-name", "*.conf", "-exec", "basename", "{}", ".conf", ";"]
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.configsReadable = true
        root.configs = Model.parseConfigs(listStdout.text)
      } else {
        // Losing the listing is not fatal: live tunnels still come from `ip`,
        // so the panel degrades to showing what is actually up.
        root.configsReadable = false
        root.configs = []
      }
      root.ensureCursor()
    }
  }

  Process {
    id: stateProc
    command: ["ip", "-o", "link", "show", "type", "wireguard"]
    stdout: StdioCollector { id: stateStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.liveInterfaces = exitCode === 0 ? Model.parseInterfaces(stateStdout.text) : []
      root.ensureCursor()
    }
  }

  Process {
    id: toggleProc
    stdout: StdioCollector { id: toggleStdout; waitForEnd: true }
    stderr: StdioCollector { id: toggleStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = Model.friendlyError(toggleStderr.text, exitCode)
      root.busy = false
      root.pendingName = ""
      // wg-quick has already returned, so the link state is settled by now.
      root.refreshState()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshState()
  }

  // The config list changes rarely; re-read it occasionally so a newly dropped
  // .conf shows up without a shell restart.
  Timer {
    interval: 120000
    running: true
    repeat: true
    onTriggered: root.refreshConfigs()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return root.summary }
    function up(name: string): string { root.setTunnel(name, true); return "ok" }
    function down(name: string): string { root.setTunnel(name, false); return "ok" }
    function toggleVpn(name: string): string { root.toggleTunnel(name); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barGlyph(root.tunnels, root.configsReadable)
    active: root.anyUp
    tooltipText: Model.tooltipText(root.tunnels, root.configsReadable)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePrimary()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.togglePrimary()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero rather than this Panel.
            readonly property bool switchOn: root.anyUp
            readonly property bool switchBusy: root.busy
            function activate() { root.togglePrimary() }

            PanelHero {
              id: hero
              width: parent.width
              title: "WireGuard"
              meta: root.summary
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.anyUp ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  text: Model.barGlyph(root.tunnels, root.configsReadable)
                  color: root.anyUp ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: root.primaryTunnel !== ""
                  checked: header.switchOn
                  busy: header.switchBusy
                  foreground: hero.foreground
                  onToggled: header.activate()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: (root.anyUp ? "Disconnect " : "Connect ") + root.primaryTunnel
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "TUNNELS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.tunnels.length === 0
              width: parent.width
              text: root.configsReadable
                ? "No WireGuard configs in /etc/wireguard."
                : "Cannot read /etc/wireguard. A passwordless sudo rule is needed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: tunnelColumn
              visible: root.tunnels.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.tunnels
                TunnelRow {
                  required property var modelData
                  required property int index
                  width: tunnelColumn.width
                  tunnel: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  component TunnelRow: CursorSurface {
    id: tunnelRow
    property var tunnel: null
    property int rowIndex: 0
    readonly property string name: tunnel ? String(tunnel.name) : ""
    readonly property bool up: tunnel ? tunnel.up === true : false
    readonly property bool pending: root.busy && root.pendingName === name

    hasCursor: root.cursorActive && root.tunnelIndex === rowIndex
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setTunnelCursor(tunnelRow.rowIndex)
      onClicked: root.toggleTunnel(tunnelRow.name)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: Model.barGlyph([tunnelRow.tunnel], true)
        color: tunnelRow.up ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: tunnelRow.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: tunnelRow.pending
            ? (root.pendingUp ? "Connecting…" : "Disconnecting…")
            : (tunnelRow.up ? "Connected" : "Disconnected")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // The row owns the click, so the switch is display-only here.
      ToggleSwitch {
        checked: tunnelRow.up
        busy: root.busy
        interactive: false
        hasCursor: tunnelRow.hasCursor
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
