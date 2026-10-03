import QtQuick
import qs.Commons

// Notification-hub (prometheus.notif-hub) face of the arXiv plugin: the same
// UI as the bar popup, in one column. Declared in manifest.json under
// "notificationCard".
Item {
  id: card

  property real hubWidth: 300
  // Unseen scan results count toward the hub's bell badge.
  readonly property int badge: data.hasUnseen ? data.totalMatches : 0
  // Called by the hub whenever the panel opens.
  function markViewed() { data.markViewed() }

  implicitHeight: view.implicitHeight

  Backend { id: data }

  View {
    id: view
    width: parent.width
    height: implicitHeight
    backend: data
    compact: true
    fg: Color.popups.text
    ff: Style.font.menuFamily
  }
}
