import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Proton VPN in the bar. All VPN I/O goes through the bundled `protonvpn-ctl`
// script, which wraps the `protonvpn` CLI and turns its tables into JSON.
// The bar icon itself only polls NetworkManager, which is far cheaper than
// spawning the Python CLI every few seconds.
Panel {
  id: root
  moduleName: "badger.protonvpn"
  ipcTarget: "badger.protonvpn"
  manageIpc: false

  readonly property string ctl: String(Qt.resolvedUrl("protonvpn-ctl")).replace(/^file:\/\//, "")
  readonly property int pollInterval: Math.max(2, Number(root.setting("pollIntervalSec", 5))) * 1000
  readonly property string quickCountry: String(root.setting("quickConnectCountry", "")).trim().toUpperCase()

  // ---- state from `protonvpn-ctl state` ----
  property bool loaded: false
  property bool installed: true
  property bool signedIn: true
  property bool connected: false
  property string server: ""
  property string city: ""
  property string country: ""
  property string countryCode: ""
  property int load: -1
  property string protocol: ""
  property var config: ({})
  property var recent: []
  property var countries: []

  // ---- cheap NetworkManager poll for the bar icon ----
  property bool barConnected: false
  property string barServer: ""

  // ---- actions ----
  property bool busy: actionProc.running
  property string busyText: ""
  property string busyTarget: ""
  property string lastError: ""
  property string lastMessage: ""

  property string query: ""
  readonly property var filteredCountries: {
    var q = query.trim().toLowerCase()
    if (q === "") return []
    var out = []
    for (var i = 0; i < countries.length; i++) {
      var c = countries[i]
      if (c.name.toLowerCase().indexOf(q) !== -1 || c.code.toLowerCase() === q) out.push(c)
    }
    return out
  }

  readonly property var quickActions: [
    { id: "fastest", label: "Fastest", args: [], tip: "Fastest server anywhere" },
    { id: "random", label: "Random", args: ["--random"], tip: "Random available server" },
    { id: "p2p", label: "P2P", args: ["--p2p"], tip: "Fastest P2P-optimized server" },
    { id: "securecore", label: "Secure Core", args: ["--securecore"], tip: "Route through a Secure Core server" }
  ]

  readonly property var settingDefs: [
    { key: "netshield", label: "NetShield", hint: "DNS-level blocking", pills: [
      { value: "off", label: "Off", tooltip: "NetShield disabled" },
      { value: "malware-only", label: "Malware", tooltip: "Block malware domains" },
      { value: "malware-ads-trackers", label: "+ Ads", tooltip: "Block malware, ads and trackers" }
    ] },
    { key: "kill-switch", label: "Kill switch", hint: "Block traffic if the VPN drops", on: "standard", off: "off" },
    { key: "vpn-accelerator", label: "VPN Accelerator", hint: "Faster speeds on distant servers", on: "on", off: "off" },
    { key: "port-forwarding", label: "Port forwarding", hint: "For P2P and self-hosting", on: "on", off: "off" },
    { key: "moderate-nat", label: "Moderate NAT", hint: "Better for gaming and P2P", on: "on", off: "off" },
    { key: "ipv6", label: "IPv6", hint: "Route IPv6 through the tunnel", on: "on", off: "off" }
  ]

  // Flat list of keyboard-navigable rows, top to bottom.
  readonly property var rows: {
    var list = []
    if (!installed) return list
    if (!signedIn) return ["signin"]
    list.push("power", "quick")
    for (var r = 0; r < recent.length; r++) list.push("recent:" + r)
    list.push("search")
    for (var c = 0; c < filteredCountries.length; c++) list.push("country:" + c)
    for (var s = 0; s < settingDefs.length; s++) list.push("set:" + settingDefs[s].key)
    return list
  }
  property int cursorRow: 0
  property int quickIndex: 0
  property bool cursorActive: false
  readonly property string cursorId: cursorActive && cursorRow < rows.length ? rows[cursorRow] : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // ---------- helpers ----------
  function flag(code) {
    var cc = String(code || "").toUpperCase()
    if (cc === "UK") cc = "GB"
    if (!/^[A-Z]{2}$/.test(cc)) return "󰖂"
    return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65)
  }

  function countryNameFor(code) {
    for (var i = 0; i < countries.length; i++) if (countries[i].code === code) return countries[i].name
    return code
  }

  function refreshState() {
    if (!stateProc.running) stateProc.running = true
  }

  function runAction(args, text, target) {
    if (busy) return
    lastError = ""
    lastMessage = ""
    busyText = text
    busyTarget = target || ""
    actionProc.command = [root.ctl].concat(args)
    actionProc.running = true
  }

  function connectCountry(code) {
    runAction(["connect", "--country", code], "Connecting to " + countryNameFor(code) + "…", "country:" + code)
  }

  function quickConnect() {
    if (quickCountry !== "") connectCountry(quickCountry)
    else runAction(["connect"], "Connecting to the fastest server…", "quick:fastest")
  }

  function runQuick(index) {
    var q = quickActions[index]
    runAction(["connect"].concat(q.args), "Connecting (" + q.label.toLowerCase() + ")…", "quick:" + q.id)
  }

  function disconnect() {
    runAction(["disconnect"], "Disconnecting…", "power")
  }

  function togglePower() {
    if (connected || barConnected) disconnect()
    else quickConnect()
  }

  function signIn() {
    Quickshell.execDetached(["xdg-terminal-exec", "--title=Proton VPN sign in", "protonvpn", "signin"])
    close()
  }

  function setOption(key, value) {
    if (settingProc.running || config[key] === value) return
    // Optimistic: flip it now, re-read on failure.
    var next = {}
    for (var k in config) next[k] = config[k]
    next[key] = value
    config = next
    lastError = ""
    settingProc.command = [root.ctl, "set", key, value]
    settingProc.running = true
  }

  function settingDef(key) {
    for (var i = 0; i < settingDefs.length; i++) if (settingDefs[i].key === key) return settingDefs[i]
    return null
  }

  function toggleSetting(key) {
    var def = settingDef(key)
    if (!def || def.pills) return
    setOption(key, config[key] === def.on ? def.off : def.on)
  }

  function cycleSetting(key, dx) {
    var def = settingDef(key)
    if (!def) return
    if (!def.pills) { setOption(key, dx > 0 ? def.on : def.off); return }
    var idx = 0
    for (var i = 0; i < def.pills.length; i++) if (def.pills[i].value === config[key]) idx = i
    idx = Math.max(0, Math.min(def.pills.length - 1, idx + dx))
    setOption(key, def.pills[idx].value)
  }

  // ---------- keyboard cursor ----------
  function setCursor(id) {
    var i = rows.indexOf(id)
    if (i < 0) return
    cursorActive = true
    cursorRow = i
  }

  function moveCursor(dx, dy) {
    if (rows.length === 0) return
    cursorRow = Math.max(0, Math.min(rows.length - 1, cursorRow))
    if (dy !== 0) {
      cursorRow = Math.max(0, Math.min(rows.length - 1, cursorRow + dy))
      return
    }
    var id = rows[cursorRow]
    if (id === "quick") quickIndex = Math.max(0, Math.min(quickActions.length - 1, quickIndex + dx))
    else if (id.indexOf("set:") === 0) cycleSetting(id.substring(4), dx)
  }

  function activateCursor() {
    var id = rows[cursorRow]
    if (!id) return
    if (id === "power") togglePower()
    else if (id === "signin") signIn()
    else if (id === "quick") runQuick(quickIndex)
    else if (id === "search") focusSearch("")
    else if (id.indexOf("recent:") === 0) connectCountry(recent[Number(id.substring(7))].code)
    else if (id.indexOf("country:") === 0) connectCountry(filteredCountries[Number(id.substring(8))].code)
    else if (id.indexOf("set:") === 0) {
      var def = settingDef(id.substring(4))
      if (def && def.pills) cycleSetting(def.key, 1)
      else toggleSetting(id.substring(4))
    }
  }

  function focusSearch(initial) {
    if (!signedIn) return
    setCursor("search")
    if (initial) searchField.text = searchField.text + initial
    searchField.forceActiveFocus()
  }

  function leaveSearch(dy) {
    keyCatcher.forceActiveFocus()
    setCursor("search")
    moveCursor(0, dy)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    pollProc.running = true
    refreshState()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorRow = 0
    lastMessage = ""
    query = ""
    searchField.text = ""
    if (panelFlick) panelFlick.contentY = 0
    refreshState()
    if (countries.length === 0 && !countriesProc.running) countriesProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onRowsChanged: if (cursorRow >= rows.length) cursorRow = Math.max(0, rows.length - 1)
  onCursorIdChanged: if (cursorId === "search") scrollItemIntoView(searchField)

  // ---------- processes ----------
  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    onTriggered: if (!pollProc.running) pollProc.running = true
  }

  Process {
    id: pollProc
    command: ["nmcli", "-t", "-f", "NAME", "connection", "show", "--active"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = ""
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++)
          if (lines[i].indexOf("ProtonVPN") === 0) found = lines[i].replace(/^ProtonVPN\s*/, "")
        var now = found !== ""
        var changed = now !== root.barConnected || found !== root.barServer
        root.barConnected = now
        root.barServer = found
        // Connected or dropped outside the panel (CLI, reconnect): resync.
        if (changed && root.loaded && !root.busy && now !== root.connected) root.refreshState()
      }
    }
  }

  Process {
    id: stateProc
    command: [root.ctl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.installed = d.installed !== false
          root.signedIn = d.signedIn !== false
          root.connected = !!d.connected
          root.server = d.server || ""
          root.city = d.city || ""
          root.country = d.country || ""
          root.countryCode = d.countryCode || ""
          root.load = d.load === undefined ? -1 : d.load
          root.protocol = d.protocol || ""
          root.config = d.config || ({})
          root.recent = d.recent || []
          if (d.error && !root.busy) root.lastError = d.error
          root.loaded = true
        } catch (e) {
          root.lastError = "Could not read Proton VPN status"
        }
      }
    }
  }

  Process {
    id: countriesProc
    command: [root.ctl, "countries"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.countries = JSON.parse(String(text || "[]")) } catch (e) { root.countries = [] }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastMessage = String(text || "").trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.lastError = String(text).trim()
    }
    onExited: function(code) {
      if (code !== 0 && root.lastError === "") root.lastError = "protonvpn failed (exit " + code + ")"
      root.busyText = ""
      root.busyTarget = ""
      root.query = ""
      searchField.text = ""
      pollProc.running = true
      root.refreshState()
    }
  }

  Process {
    id: settingProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.lastError = String(text).trim()
    }
    onExited: function(code) { if (code !== 0) root.refreshState() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshState(); return "ok" }
    function connect(country: string): string {
      if (country === "") root.quickConnect()
      else root.connectCountry(country.toUpperCase())
      return "ok"
    }
    function disconnect(): string { root.disconnect(); return "ok" }
    function toggleVpn(): string { root.togglePower(); return "ok" }
    function status(): string {
      return root.barConnected ? "connected " + root.barServer : "disconnected"
    }
  }

  // ---------- bar icon ----------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    foreground: root.barConnected ? root.barForeground : Qt.darker(root.barForeground, 1.8)
    tooltipText: root.busy ? root.busyText
               : root.barConnected ? "Proton VPN: " + root.barServer
               : "Proton VPN: disconnected"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePower()
      else if (buttonCode === Qt.MiddleButton) { pollProc.running = true; root.refreshState() }
      else root.toggle()
    }

    SequentialAnimation on opacity {
      running: root.busy
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
      onRunningChanged: if (!running) button.opacity = 1.0
    }
  }

  // ---------- panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Any other letter starts a country search ("/" just focuses it).
      onTextKey: function(t) {
        if (t === "/") root.focusSearch("")
        else if (/^[A-Za-z]$/.test(t)) root.focusSearch(t)
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

          // ---------- Hero ----------
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's trailingControl resolves `root` to PanelHero; reach
            // panel state through `header` instead.
            readonly property bool ringVisible: root.cursorId === "power"
            readonly property bool switchVisible: root.installed && root.signedIn
            readonly property bool switchOn: root.busy ? root.busyTarget !== "power" : root.connected
            readonly property bool switchBusy: root.busy
            readonly property color iconColor: root.connected ? root.foreground : root.dim
            readonly property string switchHint: root.connected ? "Disconnect"
                : root.quickCountry !== "" ? "Connect to " + root.countryNameFor(root.quickCountry)
                : "Connect to the fastest server"
            function focusHero() { root.setCursor("power") }
            function togglePower() { root.togglePower() }

            PanelHero {
              id: hero
              width: parent.width
              title: root.connected ? root.flag(root.countryCode) + "  " + (root.city || root.server) : "Proton VPN"
              meta: root.busy ? root.busyText
                  : !root.installed ? "protonvpn CLI not found"
                  : !root.signedIn ? "Signed out"
                  : root.connected ? root.country.toUpperCase()
                  : root.loaded ? "DISCONNECTED" : "CHECKING…"
              detail: {
                if (!root.connected || root.busy) return ""
                var parts = [root.server]
                if (root.load >= 0) parts.push("load " + root.load + "%")
                if (root.protocol) parts.push(root.protocol)
                return parts.join(" · ")
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.connected ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  text: "󰖂"
                  color: header.iconColor
                  font.family: hero.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: header.switchVisible
                  checked: header.switchOn
                  busy: header.switchBusy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: header.togglePower()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: header.switchHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- Not installed / signed out ----------
          CursorSurface {
            visible: !root.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "The protonvpn CLI is not installed or not on PATH."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          ActionRow {
            visible: root.installed && !root.signedIn
            width: parent.width
            rowId: "signin"
            glyph: "󰍂"
            title: "Sign in to Proton VPN"
            subtitle: "Opens a terminal running protonvpn signin"
            onChosen: root.signIn()
          }

          // ---------- Quick connect ----------
          Column {
            visible: root.installed && root.signedIn
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "QUICK CONNECT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: quickRow
              width: parent.width
              spacing: Style.spacing.xs
              readonly property real cellWidth: (width - spacing * (root.quickActions.length - 1)) / root.quickActions.length

              Repeater {
                model: root.quickActions
                Button {
                  required property var modelData
                  required property int index
                  width: quickRow.cellWidth
                  text: modelData.label
                  tooltipText: modelData.tip
                  enabled: !root.busy
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  active: root.busyTarget === "quick:" + modelData.id
                  hasCursor: root.cursorId === "quick" && root.quickIndex === index
                  onClicked: root.runQuick(index)
                  onHovered: function(on) {
                    if (!on) return
                    root.setCursor("quick")
                    root.quickIndex = index
                  }
                }
              }
            }
          }

          // ---------- Recent ----------
          Column {
            visible: root.signedIn && root.recent.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RECENT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.signedIn ? root.recent : []
              CountryRow {
                required property var modelData
                required property int index
                width: parent.width
                rowId: "recent:" + index
                code: modelData.code
                name: modelData.name
              }
            }
          }

          // ---------- Countries ----------
          Column {
            visible: root.installed && root.signedIn
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "COUNTRIES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: searchField
              width: parent.width
              foreground: root.foreground
              placeholderText: root.countries.length > 0
                ? "Search " + root.countries.length + " countries"
                : "Search countries"
              hasCursor: root.cursorId === "search" && !activeFocus
              onTextChanged: root.query = text
              onActiveFocusChanged: if (activeFocus) root.setCursor("search")
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  root.leaveSearch(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.leaveSearch(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (root.filteredCountries.length > 0) root.connectCountry(root.filteredCountries[0].code)
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  if (text !== "") text = ""
                  else keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              visible: root.query.trim() !== "" && root.filteredCountries.length === 0
              width: parent.width
              text: root.countries.length === 0 ? "Loading countries…" : "No matching countries."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.filteredCountries
              CountryRow {
                required property var modelData
                required property int index
                width: parent.width
                rowId: "country:" + index
                code: modelData.code
                name: modelData.name
              }
            }
          }

          // ---------- Settings ----------
          Column {
            visible: root.installed && root.signedIn
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.settingDefs
              SettingRow {
                required property var modelData
                width: parent.width
                def: modelData
              }
            }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // ---------- row components ----------
  component ActionRow: CursorSurface {
    id: actionRow
    signal chosen()
    property string rowId: ""
    property string glyph: ""
    property string title: ""
    property string subtitle: ""

    hasCursor: root.cursorId === rowId
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: actionLayout.implicitHeight + Style.spacing.rowPaddingX
    onHasCursorChanged: if (hasCursor) root.scrollItemIntoView(actionRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(actionRow.rowId)
      onClicked: actionRow.chosen()
    }

    RowLayout {
      id: actionLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: actionRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component CountryRow: CursorSurface {
    id: countryRow
    property string rowId: ""
    property string code: ""
    property string name: ""
    readonly property bool activeCountry: root.connected && !root.busy && root.countryCode === code
    readonly property bool connecting: root.busyTarget === "country:" + code

    hasCursor: root.cursorId === rowId
    current: activeCountry || connecting
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: countryInner.implicitHeight + Style.spacing.lg
    onHasCursorChanged: if (hasCursor) root.scrollItemIntoView(countryRow)

    Row {
      id: countryInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: root.flag(countryRow.code)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter

        SequentialAnimation on opacity {
          running: countryRow.connecting
          loops: Animation.Infinite
          NumberAnimation { to: 0.3; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: countryRow.name
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: countryRow.activeCountry
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - codeText.width - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: codeText
        textFormat: Text.PlainText
        text: countryRow.activeCountry ? "connected" : countryRow.code
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: countryMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.setCursor(countryRow.rowId)
      onClicked: if (!countryRow.activeCountry) root.connectCountry(countryRow.code)
    }

    PanelToolTip {
      visible: countryMouse.containsMouse && !countryRow.activeCountry && !root.busy
      text: "Connect to the fastest server in " + countryRow.name
      fontFamily: root.fontFamily
    }
  }

  component SettingRow: CursorSurface {
    id: settingRow
    property var def: ({})
    readonly property string rowId: "set:" + def.key
    readonly property string value: root.config[def.key] || ""

    hasCursor: root.cursorId === rowId && !!def.pills
    outline: true
    foreground: root.foreground
    implicitHeight: settingInner.implicitHeight + Style.spacing.controlGap
    onHasCursorChanged: if (hasCursor) root.scrollItemIntoView(settingRow)

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor(settingRow.rowId)
    }

    Item {
      id: settingInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(labels.implicitHeight,
                               toggle.visible ? toggle.implicitHeight : 0,
                               pills.visible ? pills.implicitHeight : 0)

      Column {
        id: labels
        anchors.left: parent.left
        anchors.right: toggle.visible ? toggle.left : pills.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: settingRow.def.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: settingRow.def.hint
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        id: toggle
        visible: !settingRow.def.pills
        checked: settingRow.value === settingRow.def.on
        busy: settingProc.running
        hasCursor: root.cursorId === settingRow.rowId
        foreground: root.foreground
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onHovered: function(on) { if (on) root.setCursor(settingRow.rowId) }
        onToggled: root.toggleSetting(settingRow.def.key)
      }

      ButtonGroup {
        id: pills
        visible: !!settingRow.def.pills
        options: settingRow.def.pills || []
        value: settingRow.value
        focusable: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        cursorIndex: {
          if (root.cursorId !== settingRow.rowId || !settingRow.def.pills) return -1
          for (var i = 0; i < settingRow.def.pills.length; i++)
            if (settingRow.def.pills[i].value === settingRow.value) return i
          return -1
        }
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onChanged: function(v) { root.setOption(settingRow.def.key, v) }
        onHovered: function(index, on) { if (on) root.setCursor(settingRow.rowId) }
      }
    }
  }
}
