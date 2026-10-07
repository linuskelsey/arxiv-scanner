import QtQuick
import qs.Commons

// Omahub (io.github.linuskelsey.omahub) face of the arXiv plugin: the same
// UI as the bar popup, in one column. Declared in manifest.json under
// "hubCard".
Item {
  id: card

  property real hubWidth: 300
  // View draws its own title, so the hub hides its title while this card is
  // expanded and overlays only a collapse chevron in the top-right corner.
  // Ignored by hubs that predate it.
  property bool hubOwnTitle: true
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
    // Keeps total implicitHeight comfortably under plugin-hub's own
    // maxCardHeight (400, in its BarWidget.qml) — past that cap the hub
    // wraps this whole card in its own Flickable (cardScroll) instead of
    // just sizing the frame to fit, and that outer Flickable scrolls the
    // header and footer along with everything else, defeating the pinned
    // header/scrollable-middle/pinned-footer layout View.qml already
    // implements internally. Picking our own smaller viewport keeps that
    // internal Flickable as the only one that ever engages here.
    papersViewportHeightOverride: 220
    fg: Color.popups.text
    ff: Style.font.menuFamily
  }
}
