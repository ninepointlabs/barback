import Quickshell
import Quickshell.Io
import QtQuick
import qs.Ui
import qs.Commons

// About-page harness for Barback.
//
// Loads the real BarWidget.qml from a scratch plugins directory with no
// residents, under the same kind of facade the host hands a bar widget, then
// drives the About page the way a user would: the 󰋽 button in the menu, the
// license, Back, the 󰋽 button in the picker, and closing the menu. It never
// presses Email or Copy, so it opens no mail app and leaves the clipboard
// alone. Results go to $BARBACK_OUT as JSON; tests/about_qml_test.sh reads it.
//
// It also mounts a standalone AboutView in a window of its own and saves that
// window's content (and nothing else) to $BARBACK_SHOT, for a look by eye.
ShellRoot {
  id: harness

  readonly property string pluginsDir: Quickshell.env("BARBACK_PLUGINS")
  readonly property string outPath: Quickshell.env("BARBACK_OUT")
  readonly property string shotPath: Quickshell.env("BARBACK_SHOT")
  readonly property string pluginDir: harness.pluginsDir + "/ninepointlabs.barback"

  property var checks: []
  property bool shotSaved: false

  function check(name, ok, detail) {
    var next = harness.checks.slice()
    next.push({ name: name, ok: ok === true, detail: String(detail === undefined ? "" : detail) })
    harness.checks = next
  }

  function walk(node, test, out) {
    if (!node) return out
    if (test(node)) out.push(node)
    var kids = node.children || []
    for (var i = 0; i < kids.length; i++) harness.walk(kids[i], test, out)
    return out
  }

  // PopupCards are windows, not items: reach them through the widget's data
  // and search each one's content.
  function findAll(name, openOnly) {
    var out = []
    var item = loader.item
    if (!item) return out
    var data = item.data || []
    for (var i = 0; i < data.length; i++) {
      var d = data[i]
      if (!d || !d.contentItem || (openOnly && d.open !== true)) continue
      // PopupCard's contentItem is an alias for its content's children.
      var roots = d.contentItem.length !== undefined ? d.contentItem : [d.contentItem]
      for (var j = 0; j < roots.length; j++)
        harness.walk(roots[j], function (o) { return o.objectName === name }, out)
    }
    return out
  }

  function find(name) {
    var all = harness.findAll(name)
    return all.length ? all[0] : null
  }

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
    position: "top"
    vertical: false
    barSize: 26
    layoutConfig: ({ left: [], center: [], right: [{ id: "ninepointlabs.barback" }] })
    _showTooltip: function (target, text) {}
    _hideTooltip: function (target) {}
    _registerClickTarget: function (target) {}
    _unregisterClickTarget: function (target) {}
    _requestPopout: function (owner) {}
    _releasePopout: function (owner) {}
    _switchPanelFrom: function (owner, direction) { return false }
    _targetBelongsToWindow: function (target, window) { return false }
    _moduleWidgets: function (id) { return loader.item ? [loader.item] : [] }
    _run: function (command) {}
    _setCenterHoverRevealSuppressed: function (value) {}
  }

  QtObject {
    id: hostShell
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
    function updateEntryInline(id, entry) { return true }
  }

  Loader {
    id: loader
    active: harness.pluginsDir !== ""
    source: harness.pluginsDir !== "" ? "file://" + harness.pluginDir + "/BarWidget.qml" : ""
    onLoaded: {
      loader.item.bar = hostBar
      loader.item.moduleName = "ninepointlabs.barback"
      loader.item.settings = ({ items: [] })
    }
  }

  // A standalone copy of the page in a window of its own, for the screenshot.
  FloatingWindow {
    id: shotWindow
    visible: harness.shotPath !== ""
    implicitWidth: 360
    implicitHeight: 560
    color: "#101315"

    Rectangle {
      id: shotFrame
      anchors.fill: parent
      color: "#101315"

      Loader {
        id: shotLoader
        x: 12
        y: 12
        width: 336
        active: harness.pluginsDir !== ""
        source: harness.pluginsDir !== "" ? "file://" + harness.pluginDir + "/AboutView.qml" : ""
        onLoaded: {
          shotLoader.item.width = 336
          shotLoader.item.foreground = "#cacccc"
          shotLoader.item.fontFamily = "CaskaydiaMono Nerd Font"
          shotLoader.item.pluginDir = harness.pluginDir
          shotLoader.item.maxHeight = 536
        }
      }
    }
  }

  property int step: 0
  readonly property var steps: [
    function () {
      var item = loader.item
      harness.check("BarWidget.qml loaded", !!item)
      var buttons = harness.findAll("aboutButton")
      harness.check("an About button in the menu and in the picker", buttons.length === 2, buttons.length)
      harness.check("About is closed at first", item.aboutOpen === false)
      item.menuOpen = true
      var menuButton = harness.findAll("aboutButton", true)[0] || null
      harness.check("the menu's About button is showing", !!menuButton)
      if (menuButton) menuButton.clicked()
      harness.check("the About button opens About in the menu", item.menuOpen === true && item.aboutOpen === true)
      var view = harness.find("aboutView")
      harness.check("the About page is showing", !!view && view.visible === true)
    },
    function () {
      var version = harness.find("aboutVersion")
      harness.check("shows the manifest version", !!version && version.text === "Version @MANIFEST_VERSION@", version ? version.text : "")
      var madeBy = harness.find("aboutMadeBy")
      harness.check("made by Nine Point Labs", !!madeBy && madeBy.text === "Nine Point Labs")
      var privacy = harness.find("aboutPrivacy")
      harness.check("states privacy", !!privacy && String(privacy.text).indexOf("no telemetry") >= 0)
      var built = harness.find("aboutBuiltWith")
      harness.check("names Quickshell and Qt versions", !!built && /^Built with Quickshell 0\.\d+, Qt 6\.\d+$/.test(built.text),
        built ? built.text : "")
      harness.check("Email and Copy buttons are there", !!harness.find("aboutEmail") && !!harness.find("aboutCopyEmail")
        && !!harness.find("aboutCopyDetails"))
      var view = harness.find("aboutView")
      harness.check("version details for the support email", !!view && /^Barback @MANIFEST_VERSION_RE@\nQuickshell 0\.\d+, Qt 6\.\d+\n/.test(view.details),
        view ? JSON.stringify(view.details) : "")
      harness.check("license text hidden at first", harness.find("aboutLicenseText").visible === false)
      harness.find("aboutLicense").clicked()
    },
    function () {
      var text = harness.find("aboutLicenseText")
      harness.check("license text readable in place", text.visible === true
        && String(text.text).indexOf("MIT License\n\nCopyright (c) 2026 Nine Point Labs\n\nPermission") === 0,
        String(text.text).substring(0, 60))
      harness.find("aboutBack").clicked()
      var item = loader.item
      harness.check("Back returns to the menu", item.aboutOpen === false && item.menuOpen === true
        && harness.find("aboutView").visible === false)
    },
    function () {
      var item = loader.item
      item.menuOpen = false
      item.openPicker()
      harness.check("the picker is open", item.pickerOpen === true)
      var pickerButton = harness.findAll("aboutButton", true)[0] || null
      harness.check("the picker's About button is there", !!pickerButton)
      if (pickerButton) pickerButton.clicked()
      harness.check("the picker's About button opens About in the menu",
        item.pickerOpen === false && item.menuOpen === true && item.aboutOpen === true)
      harness.check("the license starts hidden again", harness.find("aboutLicenseText").visible === false)
      item.close()
      harness.check("closing the menu leaves About", item.aboutOpen === false && item.menuOpen === false)
      item.menuOpen = true
      harness.check("reopening the menu shows the menu, not About", item.aboutOpen === false)
      item.menuOpen = false
    },
    function () {
      if (harness.shotPath === "" || !shotLoader.item) { harness.finish(); return }
      shotFrame.grabToImage(function (result) {
        harness.shotSaved = result.saveToFile(harness.shotPath)
        harness.finish()
      })
    }
  ]

  Timer {
    interval: 700
    running: true
    repeat: true
    onTriggered: {
      if (harness.step >= harness.steps.length) { stop(); return }
      var fn = harness.steps[harness.step]
      harness.step++
      try {
        fn()
      } catch (error) {
        harness.check("step " + harness.step + " ran without throwing", false, error)
        if (harness.step === harness.steps.length) harness.finish()
      }
    }
  }

  function finish() {
    writer.running = true
    writer.write(JSON.stringify({ checks: harness.checks, shotSaved: harness.shotSaved }, null, 2))
    writer.stdinEnabled = false
  }

  Process {
    id: writer
    command: ["bash", "-c", "cat > \"$0\"", harness.outPath]
    stdinEnabled: true
    onExited: Qt.quit()
  }

  Timer {
    interval: 20000
    running: true
    onTriggered: Qt.quit()
  }
}
