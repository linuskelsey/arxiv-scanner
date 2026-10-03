import QtQuick
import Quickshell
import Quickshell.Io

// Reads the Plugin Hub's config (if the hub is installed) so the bar
// widget can step aside when the hub is set to wrap this plugin and hide its
// bar icon. With no hub config present, `hiddenByHub` is always false.
Item {
  id: root

  property string pluginId: ""
  property var cfg: ({})
  readonly property bool hiddenByHub: cfg.hideBarWidgets === true && (cfg.cards || []).indexOf(pluginId) >= 0

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/io.github.linuskelsey.plugin-hub/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: { try { root.cfg = JSON.parse(text()) } catch (e) { root.cfg = ({}) } }
    onFileChanged: reload()
  }
}
