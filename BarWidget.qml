import QtQuick
import qs.Ui

// Scaffold. The real chip, drawer and compatibility shim land in the next
// commit; this keeps the manifest's entry point loadable so
// `omarchy plugin validate` and the test harness have something to check.
BarWidget {
  id: root
  moduleName: "ninepointlabs.barback"

  visible: false
  implicitWidth: 0
  implicitHeight: 0
}
