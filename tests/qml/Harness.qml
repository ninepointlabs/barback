import Quickshell
import Quickshell.Io
import QtQuick
import qs.Ui
import qs.Commons

// Compatibility harness for Barback.
//
// This is not a mock of Barback. It loads the real BarWidget.qml from a
// scratch copy of the plugins directory, hands it the same kind of facade the
// host hands a third-party bar widget — an actual qs.Ui PluginBarApi whose
// shell callbacks are recorded rather than executed — and then reports what
// the real hosting path did with real installed plugins.
//
// Everything it touches is scratch: HOME, the plugins directory, and the
// shell config it pretends to write. `run` is recorded, never executed, and
// tests/qml_compat_test.sh runs the whole thing inside a network namespace
// with the plugins' own helper binaries replaced by logging stubs, so a
// resident cannot reach its daemon, its API, or the live bar.
ShellRoot {
  id: harness

  readonly property string pluginsDir: Quickshell.env("BARBACK_PLUGINS")
  readonly property string outPath: Quickshell.env("BARBACK_OUT")
  readonly property int settleMs: Number(Quickshell.env("BARBACK_SETTLE") || 4000)

  readonly property var jobItems: {
    try {
      return JSON.parse(Quickshell.env("BARBACK_ITEMS") || "[]")
    } catch (error) {
      return []
    }
  }

  // The drawer entry's settings, as the shell would hold them. Writes from
  // Barback come back through here, which is how the round trip gets tested.
  property var drawerSettings: ({ items: harness.jobItems })
  property var persisted: []
  property var facadeCalls: []
  property var notes: []

  function record(call, detail) {
    var next = harness.facadeCalls.slice()
    next.push({ call: call, detail: String(detail === undefined ? "" : detail) })
    harness.facadeCalls = next
  }

  function note(text) {
    var next = harness.notes.slice()
    next.push(String(text))
    harness.notes = next
  }

  // ------------------------------------------------- the host-side facade

  PluginBarApi {
    id: hostBar
    pluginId: "ninepointlabs.barback"
    moduleName: "ninepointlabs.barback"
    shell: hostShell

    foreground: "#cacccc"
    barForeground: "#cacccc"
    background: "#101315"
    urgent: "#a55555"
    fontFamily: "CaskaydiaMono Nerd Font"
    position: Quickshell.env("BARBACK_POSITION") || "top"
    vertical: (Quickshell.env("BARBACK_POSITION") || "top") === "left"
      || (Quickshell.env("BARBACK_POSITION") || "top") === "right"
    barSize: 26
    transparent: false
    layoutConfig: ({ left: [], center: [], right: [{ id: "ninepointlabs.barback" }] })

    _showTooltip: function (target, text) { harness.record("showTooltip", text) }
    _hideTooltip: function (target) { harness.record("hideTooltip", "") }
    _registerClickTarget: function (target) { harness.record("registerClickTarget", "") }
    _unregisterClickTarget: function (target) { harness.record("unregisterClickTarget", "") }
    _requestPopout: function (owner) { harness.record("requestPopout", "") }
    _releasePopout: function (owner) { harness.record("releasePopout", "") }
    _switchPanelFrom: function (owner, direction) { harness.record("switchPanelFrom", direction); return false }
    _targetBelongsToWindow: function (target, window) { return false }
    _moduleWidgets: function (id) {
      return String(id) === "ninepointlabs.barback" && barbackLoader.item ? [barbackLoader.item] : []
    }
    // Recorded, never executed. A harness that shelled out would be exactly
    // the live side effect this run exists to avoid.
    _run: function (command) { harness.record("run", command) }
    _setCenterHoverRevealSuppressed: function (value) { harness.record("setCenterHoverRevealSuppressed", value) }
  }

  QtObject {
    id: hostShell
    readonly property string pluginId: "ninepointlabs.barback"
    readonly property var bar: null
    readonly property var barConfig: ({})
    readonly property var idleConfig: ({})

    function serviceFor(id) { return null }
    function summon(id, payload) { harness.record("summon", id); return false }
    function hide(id) { harness.record("hide", id); return false }
    function toggle(id, payload) { harness.record("toggle", id); return false }
    function isPluginOpen(id) { return false }
    function mutateShellConfig(mutator) { return false }

    // Same semantics as shell.qml's updateEntryInline: the entry is replaced
    // whole, minus its id, and the widget sees the result as new settings.
    function updateEntryInline(id, entry) {
      if (String(id) !== "ninepointlabs.barback") return false
      var next = {}
      for (var key in entry) if (key !== "id") next[key] = entry[key]
      var record = harness.persisted.slice()
      record.push(JSON.parse(JSON.stringify(next)))
      harness.persisted = record
      harness.drawerSettings = next
      if (barbackLoader.item) barbackLoader.item.settings = next
      return true
    }
  }

  // ------------------------------------------------- the empty drawer, too
  //
  // A second, independent Barback with no residents at all. The empty drawer is
  // now a small discoverable chip with a real "Add a widget" picker behind it
  // (see DEVIATIONS.md), and neither of those can be checked on an instance
  // that has residents. It shares the scratch plugins directory, so its picker
  // sees the same real installed plugins.
  property var emptyDrawerSettings: ({ items: [] })
  property var emptyPersisted: []

  PluginBarApi {
    id: emptyBar
    pluginId: "ninepointlabs.barback"
    moduleName: "ninepointlabs.barback"
    shell: emptyShell

    foreground: hostBar.foreground
    barForeground: hostBar.barForeground
    background: hostBar.background
    urgent: hostBar.urgent
    fontFamily: hostBar.fontFamily
    position: hostBar.position
    vertical: hostBar.vertical
    barSize: hostBar.barSize
    layoutConfig: ({ left: [], center: [], right: [{ id: "ninepointlabs.barback" }] })

    _showTooltip: function (target, text) { harness.record("empty:showTooltip", text) }
    _hideTooltip: function (target) {}
    _registerClickTarget: function (target) {}
    _unregisterClickTarget: function (target) {}
    _requestPopout: function (owner) { harness.record("empty:requestPopout", "") }
    _releasePopout: function (owner) {}
    _switchPanelFrom: function (owner, direction) { return false }
    _targetBelongsToWindow: function (target, window) { return false }
    _moduleWidgets: function (id) { return emptyLoader.item ? [emptyLoader.item] : [] }
    _run: function (command) { harness.record("empty:run", command) }
    _setCenterHoverRevealSuppressed: function (value) {}
  }

  QtObject {
    id: emptyShell
    readonly property string pluginId: "ninepointlabs.barback"
    readonly property var bar: null
    readonly property var barConfig: ({})
    readonly property var idleConfig: ({})

    function serviceFor(id) { return null }
    function summon(id, payload) { return false }
    function hide(id) { return false }
    function toggle(id, payload) { return false }
    function isPluginOpen(id) { return false }
    function mutateShellConfig(mutator) { return false }

    function updateEntryInline(id, entry) {
      var next = {}
      for (var key in entry) if (key !== "id") next[key] = entry[key]
      var log = harness.emptyPersisted.slice()
      log.push(JSON.parse(JSON.stringify(next)))
      harness.emptyPersisted = log
      harness.emptyDrawerSettings = next
      if (emptyLoader.item) emptyLoader.item.settings = next
      return true
    }
  }

  Loader {
    id: emptyLoader
    active: harness.pluginsDir !== ""
    source: harness.pluginsDir !== ""
      ? "file://" + harness.pluginsDir + "/ninepointlabs.barback/BarWidget.qml" : ""

    onLoaded: {
      var item = emptyLoader.item
      item.bar = emptyBar
      item.moduleName = "ninepointlabs.barback"
      item.settings = harness.emptyDrawerSettings
      harness.note("empty barback loaded")
    }
  }

  // The picker's add action shells out to `bin/barback add <id>`, the one
  // writer. tests/qml_compat_test.sh replaces the bundled CLI with a logging
  // stub, so this proves the wiring and the argv without writing any config.
  // Observed at the moment the picker opened: a successful pick closes it
  // again, so the open state cannot be read after the fact.
  property bool emptyPickerOpened: false
  property var emptyCandidatesAtOpen: []
  property string emptyPickedId: ""

  Timer {
    interval: Math.max(1500, harness.settleMs - 2500)
    running: true
    onTriggered: {
      var item = emptyLoader.item
      if (!item) return
      item.openPicker()
      harness.emptyPickerOpened = item.pickerOpen === true
      var ids = []
      for (var i = 0; i < item.pickerCandidates.length; i++)
        ids.push(String(item.pickerCandidates[i].id))
      harness.emptyCandidatesAtOpen = ids
      harness.note("empty picker candidates: " + ids.join(", "))
      if (ids.length > 0) {
        harness.emptyPickedId = ids[0]
        item.addResident(ids[0])
      }
    }
  }

  // --------------------------------------------------------- load Barback

  Loader {
    id: barbackLoader
    active: harness.pluginsDir !== ""
    source: harness.pluginsDir !== ""
      ? "file://" + harness.pluginsDir + "/ninepointlabs.barback/BarWidget.qml" : ""

    onLoaded: {
      var item = barbackLoader.item
      item.bar = hostBar
      item.moduleName = "ninepointlabs.barback"
      item.settings = harness.drawerSettings
      harness.note("barback loaded")
    }

    onStatusChanged: {
      if (status === Loader.Error) harness.note("barback failed to load: " + sourceComponent)
    }
  }

  // ------------------------------------------------------------- reporting

  function describeResident(resident) {
    var out = {
      id: resident.id,
      resolvedOk: resident.ok === true,
      reason: String(resident.reason),
      url: String(resident.url || ""),
      displayName: String(resident.displayName || ""),
      compact: resident.compact === true,
      mounted: false,
      implicitWidth: 0,
      implicitHeight: 0,
      barIsShim: false,
      shimIsPluginBarApi: false,
      shimPluginId: "",
      shimModuleName: "",
      shimVertical: null,
      moduleNameInjected: "",
      settingsInjected: {},
      usesServiceFor: false,
      serviceForReturnsNull: null,
      hasLiveService: null,
      moduleWidgetsCount: -1,
      hasOpenCloseContract: false,
      errors: []
    }

    var item = barbackLoader.item ? barbackLoader.item.hostedItemFor(resident.id) : null
    if (!item) return out

    out.mounted = true
    try {
      out.implicitWidth = Math.round(item.implicitWidth || 0)
      out.implicitHeight = Math.round(item.implicitHeight || 0)
      out.moduleNameInjected = String(item.moduleName || "")
      out.settingsInjected = JSON.parse(JSON.stringify(item.settings || {}))

      var shim = item.bar
      out.barIsShim = !!shim && shim !== hostBar
      // The shim is the real facade type, not a look-alike: the properties
      // only PluginBarApi defines have to be present on it.
      out.shimIsPluginBarApi = !!shim && shim.foreignPopoutMarker !== undefined
        && typeof shim.moduleWidgets === "function" && typeof shim.run === "function"
      if (shim) {
        out.shimPluginId = String(shim.pluginId || "")
        out.shimModuleName = String(shim.moduleName || "")
        out.shimVertical = shim.vertical === true
        out.moduleWidgetsCount = shim.moduleWidgets(resident.id).length

        if (shim.shell && typeof shim.shell.serviceFor === "function") {
          out.usesServiceFor = true
          out.serviceForReturnsNull = shim.shell.serviceFor(resident.id) === null
        }
      }

      // Widgets that route a service expose it on their root; a non-null one
      // here with a null serviceFor means the local fallback path took over.
      if ("service" in item) out.hasLiveService = item.service !== null && item.service !== undefined
      out.hasOpenCloseContract = typeof item.open === "function" && typeof item.close === "function"
    } catch (error) {
      out.errors.push(String(error))
    }
    return out
  }

  function reportEmpty() {
    var item = emptyLoader.item
    var out = {
      loaded: !!item,
      itemCount: -1,
      visible: false,
      implicitWidth: 0,
      implicitHeight: 0,
      chipText: "",
      tooltip: "",
      pickerOpen: false,
      pickerOpened: harness.emptyPickerOpened,
      candidateIds: harness.emptyCandidatesAtOpen,
      pickedId: harness.emptyPickedId,
      addError: "",
      persisted: harness.emptyPersisted
    }
    if (!item) return out
    out.itemCount = item.items.length
    out.visible = item.visible === true
    out.implicitWidth = Math.round(item.implicitWidth)
    out.implicitHeight = Math.round(item.implicitHeight)
    out.chipText = String(item.chipText)
    out.tooltip = String(item.chipTooltipText)
    out.pickerOpen = item.pickerOpen === true
    out.addError = String(item.addError || "")
    return out
  }

  function report() {
    var item = barbackLoader.item
    var result = {
      ok: !!item,
      pluginsDir: harness.pluginsDir,
      position: hostBar.position,
      vertical: hostBar.vertical,
      notes: harness.notes,
      facadeCalls: harness.facadeCalls,
      persisted: harness.persisted,
      barback: {
        loaded: !!item,
        scanned: item ? item.scanned === true : false,
        visible: item ? item.visible === true : false,
        implicitWidth: item ? Math.round(item.implicitWidth) : 0,
        implicitHeight: item ? Math.round(item.implicitHeight) : 0,
        drawerSection: item ? String(item.drawerSection) : "",
        indexedIds: item ? Object.keys(item.pluginIndex).sort() : [],
        itemIds: [],
        chipText: item ? String(item.chipText) : ""
      },
      residents: [],
      // The empty drawer, which now draws a chip of its own and owns the
      // picker. Reported separately because it is a separate instance.
      empty: harness.reportEmpty()
    }

    if (item) {
      for (var i = 0; i < item.items.length; i++) result.barback.itemIds.push(item.items[i].id)
      for (var j = 0; j < item.residents.length; j++)
        result.residents.push(harness.describeResident(item.residents[j]))
    }
    return result
  }

  Process {
    id: writer
    command: ["bash", "-c", "cat > \"$0\"", harness.outPath]
    stdinEnabled: true
    onExited: Qt.quit()
  }

  Timer {
    interval: harness.settleMs
    running: true
    onTriggered: {
      writer.running = true
      writer.write(JSON.stringify(harness.report(), null, 2))
      writer.stdinEnabled = false
    }
  }

  // Hard stop, so a wedged plugin cannot hold the harness open.
  Timer {
    interval: harness.settleMs + 15000
    running: true
    onTriggered: Qt.quit()
  }
}
