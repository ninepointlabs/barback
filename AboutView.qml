import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "About.js" as About

// The chip menu's About page: who made Barback, its version and license,
// where to get help, and what it does with your data. BarWidget.qml swaps it
// in for the menu (the 󰋽 button in the menu or picker header); Back or Esc
// returns, and closing the menu leaves it.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property string glyph: "󰀱"
  // The installed plugin folder, where manifest.json and LICENSE live.
  property string pluginDir: ""
  property real maxHeight: Style.space(460)
  property bool showLicense: false
  property string notice: ""

  signal backRequested()

  readonly property color dim: Qt.darker(root.foreground, 1.4)
  readonly property real labelWidth: Style.space(64)
  readonly property string version: About.manifestVersion(manifestFile.loaded ? manifestFile.text() : "")
  readonly property string licenseText: licenseFile.loaded ? licenseFile.text() : ""
  readonly property string quickshellVersion: About.probedVersion(function (a, b) { return Quickshell.hasVersion(a, b) }, 0)
  readonly property string qtVersion: About.probedVersion(function (a, b) { return Quickshell.hasQtVersion(a, b) }, 6)
  readonly property string details: About.details(root.version, root.quickshellVersion, root.qtVersion,
    (Quickshell.env("XDG_CURRENT_DESKTOP") || "unknown desktop") + ", " + Qt.platform.pluginName)

  implicitHeight: Math.min(column.implicitHeight, root.maxHeight)

  function copy(text, what) {
    Quickshell.clipboardText = text
    root.notice = what + " copied"
    noticeTimer.restart()
  }

  onVisibleChanged: {
    if (visible) { flick.contentY = 0; root.forceActiveFocus() }
    else { root.showLicense = false; root.notice = "" }
  }

  // Esc steps back to the menu, if the popup has the keyboard.
  Keys.onEscapePressed: function (event) { root.backRequested(); event.accepted = true }

  FileView { id: manifestFile; path: root.pluginDir && root.visible ? root.pluginDir + "/manifest.json" : ""; printErrors: false }
  FileView { id: licenseFile; path: root.pluginDir && root.visible ? root.pluginDir + "/LICENSE" : ""; printErrors: false }

  Timer { id: noticeTimer; interval: 2500; onTriggered: root.notice = "" }

  component Label: Text {
    width: root.labelWidth
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Value: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component SmallButton: Button {
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: flick.width
      spacing: Style.space(10)

      SmallButton {
        objectName: "aboutBack"
        iconText: "󰁍"
        text: "Back"
        tooltipText: "Back to the menu (Esc)"
        onClicked: root.backRequested()
      }

      Row {
        width: parent.width
        spacing: Style.space(12)

        Text {
          id: appIcon
          textFormat: Text.PlainText
          text: root.glyph
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.display * 1.5
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - appIcon.width - parent.spacing
          spacing: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: About.NAME
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: About.TAGLINE
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            objectName: "aboutVersion"
            textFormat: Text.PlainText
            text: "Version " + (root.version || "unknown")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { width: parent.width; foreground: root.foreground }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(10)
        rowSpacing: Style.space(6)
        verticalItemAlignment: Grid.AlignVCenter

        Label { text: "Made by" }
        Value { objectName: "aboutMadeBy"; text: About.ORGANIZATION }

        Label { text: "Created" }
        Value { text: About.CREATED }

        Label { text: "License" }
        Flow {
          width: column.width - root.labelWidth - Style.space(10)
          spacing: Style.space(6)
          Value {
            height: licenseButton.implicitHeight
            verticalAlignment: Text.AlignVCenter
            text: About.licenseSummary(root.licenseText) || "MIT License"
          }
          SmallButton {
            id: licenseButton
            objectName: "aboutLicense"
            text: root.showLicense ? "Hide" : "Read it"
            onClicked: root.showLicense = !root.showLicense
          }
        }

        Label { text: "Support" }
        Value { text: About.SUPPORT_EMAIL }
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        SmallButton {
          objectName: "aboutEmail"
          text: "Email"
          tooltipText: "Opens your mail app with the version details filled in"
          onClicked: Qt.openUrlExternally(About.mailto(root.version, root.details))
        }
        SmallButton {
          objectName: "aboutCopyEmail"
          text: "Copy"
          onClicked: root.copy(About.SUPPORT_EMAIL, "Address")
        }
        SmallButton {
          objectName: "aboutCopyDetails"
          text: "Copy version details"
          onClicked: root.copy(root.details, "Version details")
        }
      }

      Text {
        visible: root.notice !== ""
        textFormat: Text.PlainText
        text: root.notice
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        width: parent.width
        height: Math.min(licenseBody.implicitHeight + Style.space(16), Style.space(160))
        visible: root.showLicense
        color: "transparent"
        radius: Style.cornerRadius
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

        Flickable {
          id: licenseView
          anchors.fill: parent
          anchors.margins: Style.space(8)
          clip: true
          contentHeight: licenseBody.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Text {
            id: licenseBody
            objectName: "aboutLicenseText"
            width: licenseView.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: About.licenseBody(root.licenseText) || ("LICENSE could not be read from " + root.pluginDir + ".")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "PRIVACY"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Text {
        objectName: "aboutPrivacy"
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: About.PRIVACY
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        objectName: "aboutBuiltWith"
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Built with " + About.builtWith(root.quickshellVersion, root.qtVersion)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
