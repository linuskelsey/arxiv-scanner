import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// The arXiv UI: header, scrollable paper lists (two columns, or one when
// `compact`), Scan now / Settings. Used inside the bar popup and inside the
// notification hub; `backend` (Backend.qml) supplies data and actions.
Item {
  id: view

  required property var backend
  property color fg: Color.popups.text
  property string ff: Style.font.family
  property bool compact: false

  // Fixed height of the scrollable papers area; everything else (title,
  // Scan now/Settings, the settings form) stays put outside it. 0 means
  // "use the compact-mode default" — the hub (Card.qml) overrides this to
  // a smaller explicit value instead, since the hub wraps the whole card
  // in its own Flickable once implicitHeight passes its own 400px cap
  // (plugin-hub's maxCardHeight), and once that outer wrapper engages,
  // header/footer scroll away with everything else instead of staying
  // pinned the way this view's own internal Flickable (below) keeps them.
  property real papersViewportHeightOverride: 0
  readonly property real papersViewportHeight: papersViewportHeightOverride > 0
    ? papersViewportHeightOverride
    : Style.space(compact ? 320 : 240)
  // Fixed height of the scrollable settings-form viewport.
  readonly property real settingsViewportHeight: Style.space(200)

  implicitHeight: header.implicitHeight + Style.space(10) + papersViewportHeight + Style.space(10) + footer.implicitHeight

  component MatchCard: Column {
    id: card
    required property var modelData
    property bool expanded: false
    width: parent.width
    spacing: Style.space(2)

    // A plain Item, not a Row — Row (and other positioners) reject anchored
    // children outright ("Cannot specify anchors for items inside Row. Row
    // will not function" — and it means it: ALL children stop laying out,
    // not just the anchored one). The MouseArea needs anchors.fill to cover
    // the tile, so it lives in this wrapper instead, with the actual Row
    // as a sibling underneath it.
    Item {
      width: parent.width
      height: headerRow.implicitHeight

      // Clicking anywhere on the tile (title, author line, arrow — none
      // of them are their own click targets any more) toggles the
      // abstract. Opening the paper itself now happens from the link
      // inside the expanded abstract instead.
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: card.expanded = !card.expanded
      }

      Row {
        id: headerRow
        width: parent.width
        spacing: Style.space(6)

      Column {
        width: parent.width - toggle.implicitWidth - parent.spacing
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: (modelData.watched ? "★ " : "") + modelData.title
          color: modelData.watched ? Color.accent : view.fg
          font.family: view.ff
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          width: parent.width
          // Text.WordWrap only breaks at whitespace: a long hyphenated token
          // (e.g. "three-user-pair") that doesn't fit the remaining line width
          // just overflows past the item's edge instead of wrapping, and gets
          // silently clipped by the popup's content area. Text.Wrap adds the
          // mid-word fallback for that case.
          wrapMode: Text.Wrap
        }
        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          text: {
            var author = modelData.lead_author ? (modelData.lead_author + (modelData.has_coauthors ? " et al." : "")) : ""
            // Date only matters for watched papers — the relevant-papers column
            // is always today's scan, so a date there is redundant noise.
            var date = (modelData.watched && modelData.published) ? Qt.formatDateTime(new Date(modelData.published), "MMM d") : ""
            if (author && date) return author + " · " + date
            return author || date
          }
          color: Qt.darker(view.fg, 1.3)
          font.family: view.ff
          font.pixelSize: Style.font.caption
          font.italic: true
          width: parent.width
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.StyledText
          visible: modelData.watched === true && !!modelData.matched_author
          text: "Watching: <b>" + backend.escapeHtml(modelData.matched_author) + "</b>"
          color: Color.accent
          font.family: view.ff
          font.pixelSize: Style.font.caption
          width: parent.width
          elide: Text.ElideRight
        }
      }

      // Disclosure indicator — the Row's own MouseArea above handles the
      // click, this is just the glyph.
      Text {
        id: toggle
        textFormat: Text.PlainText
        text: card.expanded ? "▾" : "▸"
        color: Qt.darker(view.fg, 1.3)
        font.family: view.ff
        font.pixelSize: Style.font.subtitle
      }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: card.expanded
      width: parent.width
      text: modelData.summary
      color: Qt.darker(view.fg, 1.4)
      font.family: view.ff
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Text {
      textFormat: Text.PlainText
      visible: card.expanded
      text: "Open on arXiv →"
      color: Color.accent
      font.family: view.ff
      font.pixelSize: Style.font.caption
      font.underline: true

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (backend.isSafeArxivLink(modelData.link)) Qt.openUrlExternally(modelData.link)
      }
    }
  }

    // pinned while the match list underneath scrolls.
    Column {
      id: header
      width: parent.width
      spacing: Style.space(10)

      Item {
        width: parent.width
        implicitHeight: titleText.implicitHeight

        Text {
          id: titleText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: view.compact ? parent.right : modelText.left
          anchors.rightMargin: view.compact ? Style.space(28) : Style.space(8)
          text: "arXiv " + backend.category + " scan"
          color: view.fg
          font.family: view.ff
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: modelText
          textFormat: Text.PlainText
          // In the hub card the top-right corner belongs to the hub's
          // collapse chevron, so the model moves to the "Last checked" line.
          visible: backend.agentLabel !== "" && !view.compact
          anchors.right: parent.right
          anchors.baseline: titleText.baseline
          text: "model: " + backend.agentLabel
          color: Qt.darker(view.fg, 1.4)
          font.family: view.ff
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: backend.updatedAt !== ""
        text: "Last checked: " + Qt.formatDateTime(new Date(backend.updatedAt), "MMM d, hh:mm")
              + (view.compact && backend.agentLabel !== "" ? " · model: " + backend.agentLabel : "")
        color: Qt.darker(view.fg, 1.4)
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { foreground: view.fg }
    }

    // Only the paper lists scroll — fixed height, pinned between the
    // static header above and the static footer (Scan now/Settings) below.
    Flickable {
      id: scroll
      anchors.top: header.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.right: parent.right
      height: view.papersViewportHeight
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      // Collapsing an expanded abstract shrinks contentHeight, but
      // contentY doesn't auto-clamp to the new (smaller) range on its
      // own — without this you can still scroll down into the now-empty
      // space the abstract used to occupy. returnToBounds() only fires
      // off Flickable's own drag/flick state machine, which a
      // contentHeight change from an unrelated binding doesn't touch, so
      // clamp contentY directly instead.
      onContentHeightChanged: {
        var maxY = Math.max(0, contentHeight - height)
        if (contentY > maxY) contentY = maxY
      }

      Column {
        id: column
        width: scroll.width

        Grid {
          width: parent.width
          // Explicit, not implicit: the separator Rectangle below reads
          // parent.height, and this Row's implicit height is itself
          // max(children's height) — which would include that same
          // Rectangle. That's a genuine cycle in the layout graph (Row's
          // height partly determined by a child whose height comes from
          // Row's height), and it doesn't reliably reconverge when a card
          // collapses — contentHeight would grow fine but never shrink
          // back. Deriving height only from the two named columns (never
          // the separator) breaks the cycle.
          columns: view.compact ? 1 : 3
          columnSpacing: Style.space(16)
          rowSpacing: Style.space(16)

          // ---- left: top relevant papers ----
          Column {
            id: leftColumn
            // parent.width is the Row's width; the Row has 3 children
            // (this column, the separator Rectangle, the right column) so
            // there are TWO inter-child gaps plus the separator's own
            // width to subtract before halving — not just one gap.
            width: view.compact ? parent.width : (parent.width - 2 * Style.space(16) - Style.spacing.hairline) / 2
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "Recent papers of interest"
              color: Qt.darker(view.fg, 1.2)
              font.family: view.ff
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: backend.areaMatches
              MatchCard {}
            }

            Text {
              visible: backend.areaMatches.length === 0
              textFormat: Text.PlainText
              text: "No interest-area matches from the last scan."
              color: Qt.darker(view.fg, 1.4)
              font.family: view.ff
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }

          Rectangle {
            visible: !view.compact
            width: Style.spacing.hairline
            height: Math.max(leftColumn.implicitHeight, rightColumn.implicitHeight)
            color: view.fg
            opacity: 0.12
          }

          // ---- right: watched authors ----
          Column {
            id: rightColumn
            // See left column: same two-gaps-plus-separator overhead.
            width: view.compact ? parent.width : (parent.width - 2 * Style.space(16) - Style.spacing.hairline) / 2
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "Watched authors (" + backend.watchedMatches.length + ")"
              color: Qt.darker(view.fg, 1.2)
              font.family: view.ff
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: backend.watchedMatches
              MatchCard {}
            }

            Text {
              visible: backend.watchedMatches.length === 0
              textFormat: Text.PlainText
              text: backend.watchedAuthors.length === 0
                ? "No authors watched yet — add some in Settings."
                : "No recent papers from watched authors."
              color: Qt.darker(view.fg, 1.4)
              font.family: view.ff
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }

    Column {
      id: footer
      anchors.top: scroll.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(10)

      PanelSeparator { foreground: view.fg }

      // Scan now / Settings live inside the scroll now too (as the first
      // row of settingsColumn below) instead of a separately pinned Row —
      // this Flickable is always present (not gated on settingsOpen), it
      // just grows from "one button row" up to its cap once the form
      // underneath appears, so nothing sits pinned above it any more.
      Flickable {
        id: settingsScroll
        width: parent.width
        height: Math.min(settingsColumn.implicitHeight, view.settingsViewportHeight)
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: settingsColumn
          width: settingsScroll.width
          spacing: Style.space(8)

          Row {
            spacing: Style.space(8)

            Button {
              text: backend.refreshing ? "Scanning…" : "Scan now"
              foreground: view.fg
              enabled: !backend.refreshing
              onClicked: {
                backend.refreshing = true
                backend.run(backend.pluginDir + "bin/poll.py")
              }
            }

            Button {
              // Compact (hub card): opens SettingsWindow, which resets
              // settingsOpen itself on close, so the label never flips.
              text: backend.settingsOpen && !view.compact ? "Hide settings" : "Settings"
              foreground: view.fg
              onClicked: {
                backend.settingsOpen = view.compact ? true : !backend.settingsOpen
              }
            }
          }

          // Created only while open: idle TextFields would otherwise sit in
          // the shared shell and auto-read the Wayland clipboard on selection
          // change. Hub card (compact): the form lives in SettingsWindow.
          Loader {
            width: parent.width
            active: backend.settingsOpen && !view.compact
            visible: active
            sourceComponent: SettingsForm {
              backend: view.backend
              fg: view.fg
              ff: view.ff
            }
            onLoaded: item.load()
          }
        }
      }
    }
}
