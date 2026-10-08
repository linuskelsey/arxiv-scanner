import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// Pop-out window for the arXiv settings form, opened from the hub card's
// Settings button (the card is too narrow for the form). Same overlay pattern
// as Omahub's own settings: full-screen scrim, centred panel, Esc / scrim
// click closes. Lives in Card.qml, not in the hub panel, so it survives the
// panel closing on focus loss.
PanelWindow {
  id: win

  required property var backend
  property color fg: Color.menu.text
  property string ff: Style.font.menuFamily

  readonly property bool open: backend.settingsOpen
  readonly property real gap: Style.space(16)

  function close() { backend.settingsOpen = false }

  // Pin to the focused monitor each time it opens.
  onOpenChanged: {
    if (!open) return
    var want = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === want) { screen = Quickshell.screens[i]; break }
    form.load()
  }

  visible: open
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "linuskelsey-arxiv-scanner-settings"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  anchors { top: true; bottom: true; left: true; right: true }

  // Otherwise Omarchy's SUPER+W ("close window") closes whatever is behind us.
  ShortcutInhibitor {
    window: win
    enabled: win.open
  }

  Rectangle { anchors.fill: parent; color: Color.menu.scrim }
  MouseArea { anchors.fill: parent; onClicked: win.close() }

  BorderSurface {
    width: Math.min(Style.space(560), parent.width - win.gap * 2)
    height: Math.min(Style.space(640), parent.height - win.gap * 2)
    anchors.centerIn: parent
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.flat(Color.accent, Math.max(1, Style.space(2)))
    padding: Style.spacing.panelPadding

    MouseArea { anchors.fill: parent; onClicked: {} }
    Item {
      focus: true
      Keys.onEscapePressed: win.close()
      Keys.onPressed: function(event) {
        // SUPER+W is inhibited from the compositor but still reaches us.
        if (event.key === Qt.Key_W && (event.modifiers & Qt.MetaModifier)) {
          win.close()
          event.accepted = true
        }
      }
      Component.onCompleted: forceActiveFocus()
    }

    Flickable {
      anchors.fill: parent
      anchors.margins: Style.spacing.panelPadding
      contentHeight: content.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        Text {
          textFormat: Text.PlainText
          text: "arXiv Scanner settings"
          color: win.fg
          font.family: win.ff
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        SettingsForm {
          id: form
          width: parent.width
          backend: win.backend
          fg: win.fg
          ff: win.ff
        }

        Button {
          text: "Close"
          foreground: win.fg
          onClicked: win.close()
        }
      }
    }
  }
}
