import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar indicator for the daily arXiv scan: shows a count of papers Claude
// ranked as relevant plus papers by watched authors, and opens a two-column
// popup (relevant left, watched authors right). All data comes from
// state.json, written by bin/poll.py — this widget never talks to the
// network or to Claude itself.
BarWidget {
  id: root
  moduleName: "prometheus.arxiv-scanner"

  Backend { id: data }
  HubConfig { id: hub; pluginId: "prometheus.arxiv-scanner" }

  property bool popupOpen: false

  // KeyboardPanel's own close() (outside click, Escape, popout-switch to
  // another bar icon) falls back to setting its `open` property directly
  // when the owner has no close() — which clobbers the `open: root.popupOpen`
  // binding below for good, leaving the popup stuck closed on every click
  // after the first. Owning close() ourselves keeps that binding alive.
  function close() { popupOpen = false }

  // Steps aside when the Plugin Hub wraps this plugin and hides bar icons.
  visible: !hub.hiddenByHub
  implicitWidth: hub.hiddenByHub ? 0 : row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "" // nf-fa-flask
      color: root.bar ? root.bar.barForeground : "white"
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: data.refreshing ? "…" : ((data.hasUnseen ? "!" : "") + data.totalMatches)
      visible: !root.vertical
      color: root.bar ? root.bar.barForeground : "white"
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      root.popupOpen = !root.popupOpen
      if (root.popupOpen) data.markViewed()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, data.totalMatches + " arXiv match(es)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
    hoverEnabled: true
  }

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(720))
    // header + the two fixed viewports + footer chrome can add up to more
    // than the old single-scroll-region cap (520) once settings is open —
    // bump the ceiling so the footer (Save button included) doesn't get
    // clipped by the popup's own edge instead of by its own Flickable.
    contentHeight: popup.fittedContentHeight(popupView.implicitHeight, Style.space(640))

    View {
      id: popupView
      anchors.fill: parent
      backend: data
      fg: root.bar ? root.bar.foreground : Color.popups.text
      ff: root.bar ? root.bar.fontFamily : Style.font.family
    }
  }
}
