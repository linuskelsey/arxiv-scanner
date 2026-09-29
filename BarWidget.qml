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

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/prometheus.arxiv-scanner/"

  function shQuote(value) {
    return "'" + String(value).split("'").join("'\\''") + "'"
  }

  function escapeHtml(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // Fixed height of the scrollable papers area in the popup — everything
  // else (title, Scan now/Settings, the settings form) stays put outside
  // it. Starting guess; tune to taste.
  readonly property real papersViewportHeight: Style.space(240)

  // Fixed height of the scrollable settings-form viewport (only takes
  // space when the form is open — see footer.settingsScroll). Starting
  // guess; tune to taste.
  readonly property real settingsViewportHeight: Style.space(200)

  property var state: ({})
  property var config: ({})
  property var authorCheck: ({})
  property var viewed: ({})
  property bool popupOpen: false
  property bool refreshing: false
  property bool settingsOpen: false
  property bool checkingAuthors: false
  property string saveStatus: ""

  readonly property var authorCheckResults: authorCheck.results || []

  readonly property var areaMatches: state.area_matches || []
  readonly property var watchedMatches: state.watched_matches || []
  readonly property int totalMatches: areaMatches.length + watchedMatches.length
  readonly property string updatedAt: state.updated_at || ""
  // "!" badge: true whenever the latest scan hasn't been opened yet — e.g.
  // the timer fired overnight or the user just logged in and hasn't
  // clicked the bar icon since. Compares timestamps rather than ids so it
  // doesn't care whether the new scan actually changed anything.
  readonly property string lastViewedAt: viewed.viewed_at || ""
  readonly property bool hasUnseen: root.updatedAt !== "" && root.updatedAt !== root.lastViewedAt

  function markViewed() {
    if (!root.bar || root.updatedAt === "") return
    var dir = Quickshell.env("HOME") + "/.local/state/omarchy-arxiv-scanner"
    var file = dir + "/last_viewed.json"
    var json = JSON.stringify({ viewed_at: root.updatedAt })
    root.bar.run("mkdir -p " + root.shQuote(dir) + " && printf '%s' " + root.shQuote(json) + " > " + root.shQuote(file))
  }

  readonly property string category: config.category || "quant-ph"
  readonly property var interestAreas: config.interestAreas || []
  readonly property var watchedAuthors: config.watchedAuthors || []
  readonly property int maxAreaMatches: config.maxAreaMatches !== undefined ? config.maxAreaMatches : 3
  readonly property int maxWatchedMatches: config.maxWatchedMatches !== undefined ? config.maxWatchedMatches : 3
  readonly property string pollTime: config.pollTime || "07:00"

  // KeyboardPanel's own close() (outside click, Escape, popout-switch to
  // another bar icon) falls back to setting its `open` property directly
  // when the owner has no close() — which clobbers the `open: root.popupOpen`
  // binding below for good, leaving the popup stuck closed on every click
  // after the first. Owning close() ourselves keeps that binding alive.
  function close() { popupOpen = false }

  visible: true
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-arxiv-scanner/state.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.state = JSON.parse(text())
      } catch (e) {
        root.state = {}
      }
      root.refreshing = false
    }
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy-arxiv-scanner/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.config = JSON.parse(text())
      } catch (e) {
        root.config = {}
      }
    }
    onFileChanged: reload()
  }

  FileView {
    id: authorCheckFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-arxiv-scanner/author_check.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.authorCheck = JSON.parse(text())
      } catch (e) {
        root.authorCheck = {}
      }
      root.checkingAuthors = false
    }
    onFileChanged: reload()
  }

  FileView {
    id: viewedFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-arxiv-scanner/last_viewed.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.viewed = JSON.parse(text())
      } catch (e) {
        root.viewed = {}
      }
    }
    onFileChanged: reload()
  }

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
      text: root.refreshing ? "…" : ((root.hasUnseen ? "!" : "") + root.totalMatches)
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
      if (root.popupOpen) root.markViewed()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.totalMatches + " arXiv match(es)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
    hoverEnabled: true
  }

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
          color: modelData.watched ? Color.accent : root.bar.foreground
          font.family: root.bar.fontFamily
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
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
          width: parent.width
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.StyledText
          visible: modelData.watched === true && !!modelData.matched_author
          text: "Watching: <b>" + root.escapeHtml(modelData.matched_author) + "</b>"
          color: Color.accent
          font.family: root.bar.fontFamily
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
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
      }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: card.expanded
      width: parent.width
      text: modelData.summary
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Text {
      textFormat: Text.PlainText
      visible: card.expanded
      text: "Open on arXiv →"
      color: Color.accent
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.underline: true

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Qt.openUrlExternally(modelData.link)
      }
    }
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
    contentHeight: popup.fittedContentHeight(
      header.implicitHeight + Style.space(10) + root.papersViewportHeight + Style.space(10) + footer.implicitHeight,
      Style.space(640))

    // Title/timestamp/separator live outside the Flickable so they stay
    // pinned while the match list underneath scrolls.
    Column {
      id: header
      width: parent.width
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: "arXiv " + root.category + " scan"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        visible: root.updatedAt !== ""
        text: "Last checked: " + Qt.formatDateTime(new Date(root.updatedAt), "MMM d, hh:mm")
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { foreground: root.bar.foreground }
    }

    // Only the paper lists scroll — fixed height, pinned between the
    // static header above and the static footer (Scan now/Settings) below.
    Flickable {
      id: scroll
      anchors.top: header.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.right: parent.right
      height: root.papersViewportHeight
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

        Row {
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
          height: Math.max(leftColumn.implicitHeight, rightColumn.implicitHeight)
          spacing: Style.space(16)

          // ---- left: top relevant papers ----
          Column {
            id: leftColumn
            // parent.width is the Row's width; the Row has 3 children
            // (this column, the separator Rectangle, the right column) so
            // there are TWO inter-child gaps plus the separator's own
            // width to subtract before halving — not just one gap.
            width: (parent.width - 2 * Style.space(16) - Style.spacing.hairline) / 2
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "Recent papers of interest"
              color: Qt.darker(root.bar.foreground, 1.2)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: root.areaMatches
              MatchCard {}
            }

            Text {
              visible: root.areaMatches.length === 0
              textFormat: Text.PlainText
              text: "No interest-area matches from the last scan."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }

          Rectangle {
            width: Style.spacing.hairline
            height: parent.height
            color: root.bar.foreground
            opacity: 0.12
          }

          // ---- right: watched authors ----
          Column {
            id: rightColumn
            // See left column: same two-gaps-plus-separator overhead.
            width: (parent.width - 2 * Style.space(16) - Style.spacing.hairline) / 2
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "Watched authors (" + root.watchedMatches.length + ")"
              color: Qt.darker(root.bar.foreground, 1.2)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: root.watchedMatches
              MatchCard {}
            }

            Text {
              visible: root.watchedMatches.length === 0
              textFormat: Text.PlainText
              text: root.watchedAuthors.length === 0
                ? "No authors watched yet — add some in Settings."
                : "No recent papers from watched authors."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
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

      PanelSeparator { foreground: root.bar.foreground }

      // Scan now / Settings live inside the scroll now too (as the first
      // row of settingsColumn below) instead of a separately pinned Row —
      // this Flickable is always present (not gated on settingsOpen), it
      // just grows from "one button row" up to its cap once the form
      // underneath appears, so nothing sits pinned above it any more.
      Flickable {
        id: settingsScroll
        width: parent.width
        height: Math.min(settingsColumn.implicitHeight, root.settingsViewportHeight)
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
              text: root.refreshing ? "Scanning…" : "Scan now"
              foreground: root.bar.foreground
              enabled: !root.refreshing
              onClicked: {
                if (!root.bar) return
                root.refreshing = true
                root.bar.run(root.pluginDir + "bin/poll.py")
              }
            }

            Button {
              text: root.settingsOpen ? "Hide settings" : "Settings"
              foreground: root.bar.foreground
              onClicked: {
                root.settingsOpen = !root.settingsOpen
                if (root.settingsOpen) {
                  categoryField.text = root.category
                  interestsField.text = root.interestAreas.join(", ")
                  authorsField.text = root.watchedAuthors.join(", ")
                  maxAreaField.text = String(root.maxAreaMatches)
                  maxWatchedField.text = String(root.maxWatchedMatches)
                  pollTimeField.text = root.pollTime
                  root.saveStatus = ""
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.settingsOpen

          Text {
            textFormat: Text.PlainText
            text: "arXiv category (e.g. quant-ph, cs.CR, cs.LG — matches https://arxiv.org/list/<category>/new)"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          TextField {
            id: categoryField
            width: parent.width
            placeholderText: "quant-ph"
          }

          Text {
            textFormat: Text.PlainText
            text: "Interest areas (comma-separated) — Claude ranks new papers against these"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          TextField {
            id: interestsField
            width: parent.width
            placeholderText: "e.g. QKD, quantum networking"
          }

          Text {
            textFormat: Text.PlainText
            text: "Watched authors (comma-separated) — their new papers always show up on the right"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          TextField {
            id: authorsField
            width: parent.width
            placeholderText: "e.g. Stefano Pirandola, John Preskill"
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: root.checkingAuthors ? "Checking…" : "Check authors"
              foreground: root.bar.foreground
              enabled: !root.checkingAuthors && authorsField.text.trim() !== ""
              onClicked: {
                if (!root.bar) return
                root.checkingAuthors = true
                root.bar.run(root.pluginDir + "bin/check-authors.py --authors "
                  + root.shQuote(authorsField.text) + " --category " + root.shQuote(categoryField.text || "quant-ph"))
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.checkingAuthors
            text: "Querying arXiv per author (a few seconds each, be patient)…"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.checkingAuthors && root.authorCheckResults.length > 0

            Repeater {
              model: root.authorCheckResults

              Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: (modelData.found ? "✓ " : "✗ ") + modelData.name
                    + (modelData.found
                      ? " — " + modelData.total_count + " paper(s) in " + root.category
                        + (modelData.recent && modelData.recent.length > 0 ? ", " + modelData.recent.length + " in the last 30 days" : ", none in the last 30 days")
                      : " — no papers found in " + root.category + ". Check spelling (arXiv wants \"Firstname Lastname\") or that they publish in this category.")
                  color: modelData.found ? Qt.darker(root.bar.foreground, 1.2) : Color.urgent
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(12)

            Column {
              width: (parent.width - Style.space(24)) / 3
              spacing: Style.space(4)
              Text {
                textFormat: Text.PlainText
                text: "Max relevant"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: maxAreaField
                width: parent.width
                placeholderText: "3"
                validator: IntValidator { bottom: 0; top: 20 }
              }
            }

            Column {
              width: (parent.width - Style.space(24)) / 3
              spacing: Style.space(4)
              Text {
                textFormat: Text.PlainText
                text: "Max watched"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: maxWatchedField
                width: parent.width
                placeholderText: "3"
                validator: IntValidator { bottom: 0; top: 20 }
              }
            }

            Column {
              width: (parent.width - Style.space(24)) / 3
              spacing: Style.space(4)
              Text {
                textFormat: Text.PlainText
                text: "Scan time (24h)"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: pollTimeField
                width: parent.width
                placeholderText: "07:00"
              }
            }
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: "Save"
              foreground: root.bar.foreground
              onClicked: {
                if (root.bar) {
                  var cmd = root.pluginDir + "bin/save-settings.sh"
                    + " --category " + root.shQuote(categoryField.text)
                    + " --interests " + root.shQuote(interestsField.text)
                    + " --authors " + root.shQuote(authorsField.text)
                    + " --max-area " + root.shQuote(maxAreaField.text || "3")
                    + " --max-watched " + root.shQuote(maxWatchedField.text || "3")
                    + " --poll-time " + root.shQuote(pollTimeField.text || "07:00")
                  root.bar.run(cmd)
                }
                root.saveStatus = "Saved — applies on the next scan (scan time takes effect immediately)."
              }
            }
          }

          Text {
            visible: root.saveStatus !== ""
            textFormat: Text.PlainText
            text: root.saveStatus
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          }
        }
      }
    }
    }
  }
