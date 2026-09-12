import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Barback: a drawer on the bar that holds other plugins' bar widgets.
//
// Route B from the design spec — hosted widget loading. The shell's bar
// layout is flat ({id, ...settings} in left/center/right), so a drawer cannot
// be expressed as config. It is a plugin that mounts other plugins' QML
// itself, the same way shell.qml does: Qt.createComponent on the entry point
// named by the resident's manifest, then inject the three properties the bar
// injects into every widget slot — `bar`, `moduleName`, `settings`.
//
// The only thing Barback owes a hosted widget is a believable `bar`. It gets
// a real qs.Ui PluginBarApi, the exact type the host hands a third-party
// widget, with its scalars bound to Barback's own facade and its operations
// delegated back through it. Mirroring the type rather than hand-rolling an
// object means a widget that reaches for a facade member the design spec's
// delegation table never listed (`run`, `clickTargets`, `targetBelongsToWindow`,
// the ones PopupCard and WidgetButton use internally) finds it there.
//
// Nothing here throws. A resident that is gone gets pruned, a resident that
// cannot be drawn gets an inert placeholder, and either way the bar keeps its
// other widgets. A drawer that goes quiet beats a bar that dies.
BarWidget {
  id: root
  moduleName: "ninepointlabs.barback"

  // ------------------------------------------------------------- settings

  readonly property var items: Model.normalizeItems(setting("items", []))
  readonly property bool expandOnHover: setting("expandOnHover", true) === true
  readonly property bool showCount: setting("showCount", true) === true
  readonly property bool escToClose: setting("escToClose", true) === true

  // ------------------------------------------------------ plugin scanning

  // Third-party plugins do not receive `pluginRegistry` or `manifest` — a bar
  // widget is handed `bar`, `moduleName` and `settings` and nothing else — so
  // the catalogue is rebuilt from disk with the same scan PluginRegistry runs.
  // The plugins directory is this file's own parent, which survives being
  // installed somewhere other than the default path.
  readonly property string pluginsDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    var dir = decodeURIComponent(url).replace(/\/$/, "")
    var slash = dir.lastIndexOf("/")
    var parent = slash > 0 ? dir.substring(0, slash) : ""
    return parent || (Quickshell.env("HOME") + "/.config/omarchy/plugins")
  }

  // `for sub in "$dir"/*/` is the shell's own scan, and its glob never
  // matches a dot-directory — which is exactly why an `omarchy plugin remove`
  // backup (.ninepointlabs.dopewars.bak.20260909154215 and friends) can never
  // be resolved into the drawer. Model.buildIndex re-checks it anyway.
  readonly property string scanScript: '
    dir="$0"
    [ -d "$dir" ] || { printf "[]"; exit 0; }
    for sub in "$dir"/*/; do
      sub="${sub%/}"
      [ -f "$sub/manifest.json" ] || continue
      jq -c --arg dir "${sub##*/}" --arg path "$sub" \
        "{dir:\\$dir,path:\\$path,manifest:.}" "$sub/manifest.json" 2>/dev/null
    done | jq -sc "."
  '

  property var pluginIndex: ({})
  property bool scanned: false
  property bool scanPending: false

  readonly property var residents: Model.resolveAll(items, pluginIndex)
  readonly property bool hasUnresolved: {
    for (var i = 0; i < items.length; i++) if (!pluginIndex[items[i].id]) return true
    return false
  }

  function rescan() {
    if (scanner.running) {
      root.scanPending = true
      return
    }
    scanner.command = ["bash", "-c", root.scanScript, root.pluginsDir]
    scanner.running = true
  }

  function applyScan(text) {
    var records = []
    try {
      records = JSON.parse(String(text || "[]"))
    } catch (error) {
      console.warn("barback: could not read " + root.pluginsDir + ": " + error)
      return
    }
    root.pluginIndex = Model.buildIndex(records)
    root.scanned = true
    Qt.callLater(root.pruneResidents)
  }

  // Prune only against a scan that actually happened. Before the first one the
  // index is empty and every resident would look uninstalled.
  function pruneResidents() {
    if (!root.scanned) return
    var result = Model.prune(root.items, root.pluginIndex)
    if (!result.changed) return
    var log = Model.pruneLog(result.pruned)
    for (var i = 0; i < log.length; i++) console.log(log[i])
    root.persistItems(result.items)
  }

  Process {
    id: scanner
    stdout: StdioCollector {
      onStreamFinished: root.applyScan(text)
    }
    stderr: StdioCollector {}
    onExited: function (code) {
      if (code !== 0) console.warn("barback: plugin scan exited " + code)
      if (root.scanPending) {
        root.scanPending = false
        Qt.callLater(root.rescan)
      }
    }
  }

  Component.onCompleted: root.rescan()
  onItemsChanged: if (root.hasUnresolved) Qt.callLater(root.rescan)

  // ------------------------------------------------------------ persisting

  // updateEntryInline replaces a layout entry whole, so every write has to
  // carry the entry's other settings with it.
  function persistItems(nextItems) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      console.warn("barback: no shell facade, cannot persist the drawer")
      return false
    }
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.items = Model.serializeItems(Model.normalizeItems(nextItems))
    if (root.drawerSection) entry.section = root.drawerSection
    return bar.shell.updateEntryInline(root.moduleName, entry) !== false
  }

  // Which section the drawer itself sits in. The shell derives that from the
  // array an entry lives in and ignores a `section` key, but the spec's State
  // shape carries one, so it is kept truthful rather than dropped.
  readonly property string drawerSection: {
    var layout = bar && bar.layoutConfig ? bar.layoutConfig : null
    var location = Model.findDrawerEntry({ bar: { layout: layout } }, root.moduleName)
    return location.found ? location.section : ""
  }

  function eject(id) {
    root.persistItems(Model.removeItem(root.items, id))
  }

  function ejectAll() {
    root.persistItems([])
  }

  // A hosted widget calling updateEntryInline on its own id lands here: fold
  // its settings into its slot of our entry, leaving its neighbours alone.
  function updateResidentSettings(id, entry) {
    var merged = Model.mergeItemSettings(root.items, id, entry)
    if (JSON.stringify(Model.serializeItems(merged)) === JSON.stringify(Model.serializeItems(root.items)))
      return true
    return root.persistItems(merged)
  }

  // -------------------------------------------------------- live instances

  // id -> the hosted widget item this Barback instance currently has mounted.
  // The shim's moduleWidgets(id) walks every Barback across every monitor and
  // collects each one's copy, which is the cross-monitor answer the stock bar
  // gives a widget that is actually in the layout.
  property var liveItems: ({})

  function registerLive(id, item) {
    var next = ({})
    for (var key in liveItems) next[key] = liveItems[key]
    if (item) next[id] = item
    else delete next[id]
    liveItems = next
  }

  function hostedItemFor(id) {
    return liveItems[String(id || "")] || null
  }

  function hostedWidgets(id) {
    var hosts = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(root.moduleName) : []
    if (!hosts || hosts.length === 0) hosts = [root]
    var out = []
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i]
      if (!host || typeof host.hostedItemFor !== "function") continue
      var item = host.hostedItemFor(id)
      if (item) out.push(item)
    }
    return out
  }

  // -------------------------------------------------------------- badges

  // The optional, soft attention convention. Re-read whenever a resident
  // mounts or the drawer opens; widgets that never declare `barbackBadge`
  // simply never signal.
  property var badges: []

  function refreshBadges() {
    var next = []
    for (var i = 0; i < root.residents.length; i++)
      next.push(Model.badgeValue(root.hostedItemFor(root.residents[i].id)))
    root.badges = next
  }

  readonly property int badgeTotal: Model.badgeTotal(root.badges)

  Timer {
    // Cheap poll rather than a per-widget Connections: `barbackBadge` is an
    // optional convention, so there is no signal to rely on and no widget to
    // blame when there isn't one.
    interval: 2000
    running: root.visible && root.residents.length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshBadges()
  }

  // ------------------------------------------------------- expand and pin

  property bool pinned: false
  property bool hovered: false
  property bool menuOpen: false

  // A hosted widget's popup anchors into this row, so the drawer must stay
  // open while one is showing or the anchor slides out from under it.
  readonly property bool residentPopoutOpen: {
    if (!bar || !bar.activePopout) return false
    return bar.activePopout !== bar.foreignPopoutMarker
  }

  readonly property bool autoExpand: Model.wantsAutoExpand(root.residents, root.badges)
  readonly property bool expanded: root.residents.length > 0
    && (root.pinned || residentPopoutOpen || autoExpand || (root.expandOnHover && root.hovered))

  property real revealProgress: expanded ? 1 : 0
  // Matches omarchy.tray's drawer transition so the two read as one gesture.
  readonly property int animationDuration: 600
  readonly property real drawerExtent: root.vertical ? residentsGrid.implicitHeight : residentsGrid.implicitWidth
  readonly property real revealExtent: Math.round(drawerExtent * revealProgress)

  Behavior on revealProgress {
    NumberAnimation { duration: root.animationDuration; easing.type: Easing.OutCubic }
  }

  function close() {
    root.pinned = false
    root.menuOpen = false
  }

  // Zero residents means zero bar space: the chip is not drawn at all.
  visible: root.items.length > 0
  clip: false
  implicitWidth: root.vertical ? root.barSize : Math.round(chip.implicitWidth + revealExtent)
  implicitHeight: root.vertical ? Math.round(chip.implicitHeight + revealExtent) : root.barSize

  // The bar draws the open-panel dot over the whole slot otherwise, which on
  // an expanded drawer is a very long underline.
  readonly property real openPanelIndicatorWidth: chip.implicitWidth
  readonly property real openPanelIndicatorHeight: chip.implicitHeight

  HoverHandler {
    id: drawerHover
    onHoveredChanged: root.hovered = hovered
  }

  // ------------------------------------------------------------- the chip

  WidgetButton {
    id: chip
    bar: root.bar
    x: 0
    y: 0
    width: implicitWidth
    height: implicitHeight
    text: root.chipText
    active: root.pinned || root.menuOpen
    tooltipText: Model.chipTooltip(root.residents, root.badgeTotal)

    onPressed: function (button) {
      if (button === Qt.RightButton) root.menuOpen = !root.menuOpen
      else if (button === Qt.MiddleButton) root.close()
      else root.pinned = !root.pinned
    }

    // Attention dot. Badge only, never auto-expand, unless a resident asked
    // for auto-expand in its own settings.
    Rectangle {
      visible: root.badgeTotal > 0 && !root.expanded
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      x: parent.width - width - Style.space(3)
      y: Style.space(3)
    }
  }

  readonly property string chipGlyph: "󰀱"
  readonly property string chipText: {
    var live = 0
    for (var i = 0; i < residents.length; i++) if (residents[i].ok) live++
    if (!showCount || expanded || live <= 0) return chipGlyph
    return chipGlyph + " " + live
  }

  // ---------------------------------------------------------- the drawer

  Item {
    id: drawerClip
    x: root.vertical ? 0 : chip.implicitWidth
    y: root.vertical ? chip.implicitHeight : 0
    width: root.vertical ? root.barSize : root.revealExtent
    height: root.vertical ? root.revealExtent : root.barSize
    clip: true

    // Slide out from behind the chip rather than fading in place, so the
    // motion reads as a drawer opening along the bar axis.
    Grid {
      id: residentsGrid
      x: root.vertical ? 0 : root.revealExtent - root.drawerExtent
      y: root.vertical ? root.revealExtent - root.drawerExtent : 0
      rows: root.vertical ? Math.max(1, root.residents.length) : 1
      columns: root.vertical ? 1 : Math.max(1, root.residents.length)
      spacing: Style.space(1)

      Repeater {
        model: root.residents
        delegate: ResidentSlot {}
      }
    }
  }

  // ------------------------------------------------------- right-click menu

  PopupCard {
    id: menu
    anchorItem: chip
    owner: root
    bar: root.bar
    open: root.menuOpen
    contentWidth: menu.fittedContentWidth(Style.space(240))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight)

    readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
    readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(6)

      Row {
        spacing: Style.space(8)
        Text {
          text: root.chipGlyph
          color: menu.foreground
          font.family: menu.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: "Barback"
          color: menu.foreground
          font.family: menu.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      PanelSeparator { width: menuColumn.width }

      Repeater {
        model: root.residents
        delegate: MenuRow {
          required property var modelData
          width: menuColumn.width
          label: modelData.displayName || modelData.id
          detail: modelData.ok ? "" : Model.reasonText(modelData.reason)
          onActivated: root.eject(modelData.id)
        }
      }

      Text {
        visible: root.residents.length === 0
        text: "The drawer is empty."
        color: Qt.darker(menu.foreground, 1.5)
        font.family: menu.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      PanelSeparator { width: menuColumn.width }

      // Deliberately not a plugin picker: the chip holds a membership list
      // and hands the choosing to Barkeep.
      MenuRow {
        width: menuColumn.width
        label: "Add a plugin…"
        onActivated: { root.close(); root.summonBarkeep() }
      }

      MenuRow {
        width: menuColumn.width
        label: "Manage in Barkeep…"
        onActivated: { root.close(); root.summonBarkeep() }
      }

      MenuRow {
        width: menuColumn.width
        label: "Eject all"
        enabled: root.residents.length > 0
        onActivated: { root.close(); root.ejectAll() }
      }
    }
  }

  // Barback's shell facade is scoped to its own id, so it cannot summon
  // another plugin directly; the keybind path the user already has is the
  // supported way in.
  function summonBarkeep() {
    if (bar && typeof bar.run === "function")
      bar.run("omarchy-shell shell toggle ninepointlabs.barkeep")
  }

  component MenuRow: Item {
    id: menuRow
    property string label: ""
    property string detail: ""
    property bool enabled: true
    signal activated()

    implicitHeight: Style.space(26)

    Rectangle {
      anchors.fill: parent
      radius: Math.max(2, Style.cornerRadius)
      color: rowMouse.containsMouse && menuRow.enabled
        ? Style.hoverFillFor(menu.foreground, menu.foreground) : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.right: detailText.left
      anchors.rightMargin: Style.space(6)
      text: menuRow.label
      color: menuRow.enabled ? menu.foreground : Qt.darker(menu.foreground, 1.8)
      font.family: menu.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: detailText
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      text: menuRow.detail
      color: root.bar ? root.bar.urgent : Color.urgent
      font.family: menu.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: menuRow.enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: menuRow.activated()
    }
  }

  // ------------------------------------------------------------ Esc to close

  // The bar's own layer surface takes no keyboard focus, so an inline Keys
  // handler in a bar widget never fires. A pinned drawer is an explicit,
  // momentary state the user clicked into, so it mounts the same kind of
  // focus-primed layer surface omarchy's keyboard-driven bar panels use —
  // brief Exclusive to acquire focus on map, then OnDemand — and drops it
  // again the moment the drawer unpins. Hovering never takes focus.
  //
  // Set `escToClose: false` in the drawer's entry to drop the surface
  // entirely; the drawer then closes by clicking the chip again, and nothing
  // Barback does can ever take focus from the window you are typing in.
  Loader {
    active: root.pinned && root.escToClose
    sourceComponent: escCatcher
  }

  Component {
    id: escCatcher

    PanelWindow {
      id: catcher
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      implicitWidth: 1
      implicitHeight: 1
      screen: root.QsWindow.window ? root.QsWindow.window.screen : null
      anchors.top: true
      anchors.left: true

      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "barback-esc"
      WlrLayershell.keyboardFocus: primed ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

      property bool primed: true

      Timer {
        interval: 60
        running: true
        onTriggered: catcher.primed = false
      }

      // Clicking anywhere outside the bar unpins too, the same dismissal
      // PopupCard gets from its focus grab.
      HyprlandFocusGrab {
        active: true
        windows: root.QsWindow.window ? [catcher, root.QsWindow.window] : [catcher]
        onCleared: root.pinned = false
      }

      Item {
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onEscapePressed: function (event) {
          root.close()
          event.accepted = true
        }
        Component.onCompleted: Qt.callLater(function () { forceActiveFocus() })
      }
    }
  }

  // ------------------------------------------------------------- residents

  // One hosted widget: its shim facades, its Loader, and the inert
  // placeholder it falls back to. Everything in here is guarded — a resident
  // that fails to load costs the drawer one grey chip and one log line.
  component ResidentSlot: Item {
    id: slot

    required property var modelData
    readonly property var resident: slot.modelData
    readonly property string residentId: resident ? String(resident.id) : ""
    readonly property bool loadable: !!resident && resident.ok === true
    readonly property bool failed: hostedLoader.status === Loader.Error
    readonly property bool drawable: loadable && !failed && hostedLoader.item !== null
    readonly property string reason: failed ? "load-failed" : (resident ? resident.reason : "missing")

    // Barback owns the settings it injects, so the per-item compact toggle is
    // expressed as settings the hosted widget already understands.
    readonly property var hostedSettings: resident
      ? Model.hostedSettings(resident.settings, resident.compact) : ({})

    implicitWidth: root.vertical ? root.barSize
      : (drawable ? Math.max(1, hostedLoader.item.implicitWidth) : placeholder.implicitWidth)
    implicitHeight: root.vertical
      ? (drawable ? Math.max(1, hostedLoader.item.implicitHeight) : placeholder.implicitHeight)
      : root.barSize

    // ---- the compatibility shim
    //
    // A real PluginBarApi, so the hosted widget cannot tell the difference by
    // probing for a member. Scalars copied from Barback's own facade,
    // operations delegated through it.
    PluginBarApi {
      id: shimBar
      pluginId: root.moduleName
      moduleName: slot.residentId
      shell: shimShell

      foreground: root.bar ? root.bar.foreground : Color.foreground
      barForeground: root.bar ? root.bar.barForeground : Color.foreground
      background: root.bar ? root.bar.background : Color.background
      urgent: root.bar ? root.bar.urgent : Color.urgent
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      position: root.bar ? root.bar.position : "top"
      // Vertical bars get `vertical: true` passed straight through, so hosted
      // widgets pick their own compact forms for free.
      vertical: root.bar ? root.bar.vertical : false
      barSize: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal
      transparent: root.bar ? root.bar.transparent : false
      foregroundAnimationEnabled: root.bar ? root.bar.foregroundAnimationEnabled : true
      centerSectionRevealHeld: root.bar ? root.bar.centerSectionRevealHeld : false
      _centerHoverRevealSuppressed: root.bar ? root.bar.centerHoverRevealSuppressed : false
      activePopout: root.bar ? root.bar.activePopout : null
      clickTargets: root.bar ? root.bar.clickTargets : []
      layoutConfig: root.bar ? root.bar.layoutConfig : ({})

      _showTooltip: function (target, text) { if (root.bar) root.bar.showTooltip(target, text) }
      _hideTooltip: function (target) { if (root.bar) root.bar.hideTooltip(target) }
      _registerClickTarget: function (target) { if (root.bar) root.bar.registerClickTarget(target) }
      _unregisterClickTarget: function (target) { if (root.bar) root.bar.unregisterClickTarget(target) }
      _requestPopout: function (owner) { if (root.bar) root.bar.requestPopout(owner) }
      _releasePopout: function (owner) { if (root.bar) root.bar.releasePopout(owner) }
      _switchPanelFrom: function (owner, direction) {
        return root.bar ? root.bar.switchPanelFrom(owner, direction) : false
      }
      _targetBelongsToWindow: function (target, window) {
        return root.bar ? root.bar.targetBelongsToWindow(target, window) : false
      }
      // Barback tracks its residents across every monitor, so this can answer
      // for the hosted widget as well as the stock bar answers for its own.
      _moduleWidgets: function (requestedId) {
        return String(requestedId || "") === slot.residentId ? root.hostedWidgets(slot.residentId) : []
      }
      _run: function (command) { if (root.bar) root.bar.run(command) }
      _setCenterHoverRevealSuppressed: function (value) {
        if (root.bar) root.bar.setCenterHoverRevealSuppressed(value)
      }
    }

    QtObject {
      id: shimShell

      readonly property string pluginId: slot.residentId
      readonly property var bar: root.bar && root.bar.shell ? root.bar.shell.bar : null
      readonly property var barConfig: root.bar && root.bar.shell ? root.bar.shell.barConfig : ({})
      readonly property var idleConfig: root.bar && root.bar.shell ? root.bar.shell.idleConfig : ({})
      readonly property var appLibrary: null

      // Deliberately null. Every widget in the wild writes
      //   sharedService: bar.shell.serviceFor(moduleName) ... : null
      //   service: sharedService || localService
      //   Service { active: sharedService === null }
      // so returning null puts the widget on its own tested local-service
      // path instead of a service instance Barback has no right to hand out.
      function serviceFor(id) { return null }
      function firstPartyServiceFor(id) { return null }
      function pluginShellForBarEntry(ownerId, name) { return null }

      // The hosted widget's panel lives inside this drawer, so open/close
      // route to the widget itself rather than through the shell's panel host
      // (which is not mounting this plugin while it is a resident).
      function summon(id, payloadJson) { return slot.callHosted(id, "open") }
      function hide(id) { return slot.callHosted(id, "close") }
      function toggle(id, payloadJson) { return slot.callHosted(id, "togglePanel", "toggle") }
      function isPluginOpen(id) {
        if (String(id || "") !== slot.residentId) return false
        var item = hostedLoader.item
        return !!item && item.opened === true
      }

      function updateEntryInline(id, entry) {
        if (String(id || "") !== slot.residentId) return false
        return root.updateResidentSettings(slot.residentId, entry)
      }

      // Barback is not a bar replacement and holds no capability to rewrite
      // the shell config on another plugin's behalf.
      function mutateShellConfig(mutator) { return false }
    }

    function callHosted(id, method, fallbackMethod) {
      if (String(id || "") !== slot.residentId) return false
      var item = hostedLoader.item
      if (!item) return false
      if (typeof item[method] === "function") { item[method](); return true }
      if (fallbackMethod && typeof item[fallbackMethod] === "function") { item[fallbackMethod](); return true }
      return false
    }

    // ---- the hosted widget

    Loader {
      id: hostedLoader
      active: slot.loadable
      asynchronous: true
      source: slot.loadable ? slot.resident.url : ""
      // A hosted widget sizes itself; the slot tracks it rather than the
      // other way round, so a wide chip is not clipped to an icon slot.
      width: slot.implicitWidth
      height: slot.implicitHeight
      visible: slot.drawable

      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
        root.registerLive(slot.residentId, hostedLoader.item)
        Qt.callLater(root.refreshBadges)
      }

      onStatusChanged: {
        if (status !== Loader.Error) return
        // One line, no throw, no broken bar.
        console.warn("barback: " + slot.residentId + " did not load from "
          + slot.resident.url + " — showing a placeholder")
        root.registerLive(slot.residentId, null)
      }
    }

    function injectProps() {
      var target = hostedLoader.item
      if (!target) return
      // Exactly the three properties Bar.qml's ModuleSlot.injectProps sets.
      if ("bar" in target) target.bar = shimBar
      if ("moduleName" in target) target.moduleName = slot.residentId
      if ("settings" in target) target.settings = slot.hostedSettings
    }

    onHostedSettingsChanged: injectProps()
    Component.onDestruction: root.registerLive(slot.residentId, null)

    // ---- the placeholder
    //
    // Still installed, cannot be drawn: an inert chip that says so, rather
    // than a gap that says nothing.
    WidgetButton {
      id: placeholder
      bar: root.bar
      anchors.fill: parent
      visible: !slot.drawable
      text: "󰖚"
      dimmed: true
      pressable: false
      tooltipText: (slot.resident && slot.resident.displayName ? slot.resident.displayName : slot.residentId)
        + " — " + Model.reasonText(slot.reason)
    }
  }
}
