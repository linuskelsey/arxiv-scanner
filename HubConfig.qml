import QtQuick
import Quickshell
import Quickshell.Io

// Reads the notification hub's config (if the hub is installed) so the bar
// widget can step aside when the hub is set to wrap this plugin and hide its
// bar icon. With no hub config present, `hiddenByHub` is always false.
Item {
  id: root

  property string pluginId: ""
  property var cfg: ({})
  readonly property bool hiddenByHub: cfg.hideBarWidgets === true && (cfg.cards || []).indexOf(pluginId) >= 0

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/prometheus-notif-hub/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: { try { root.cfg = JSON.parse(text()) } catch (e) { root.cfg = ({}) } }
    onFileChanged: reload()
  }
}
