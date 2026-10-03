import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Non-visual half of the arXiv widget: state files, derived values and the
// actions the UI triggers. Shared by the bar widget (BarWidget.qml) and the
// notification-hub card (Card.qml) so both show the same data and behave
// the same way. View.qml is the matching UI.
Item {
  id: root

  // Same as bar.run(): a login shell, detached.
  function run(command) {
    if (!command) return
    Quickshell.execDetached(["bash", "-lc", command])
  }

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/prometheus.arxiv-scanner/"

  function shQuote(value) {
    return "'" + String(value).split("'").join("'\\''") + "'"
  }

  function escapeHtml(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    return typeof url === "string" && /^https:\/\/(www\.)?arxiv\.org\/abs\/[A-Za-z0-9._\/-]+$/.test(url)
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
  property bool refreshing: false
  property bool settingsOpen: false
  property bool checkingAuthors: false
  property string saveStatus: ""

  readonly property var authorCheckResults: authorCheck.results || []

  readonly property var areaMatches: state.area_matches || []
  readonly property var watchedMatches: state.watched_matches || []
  readonly property int totalMatches: areaMatches.length + watchedMatches.length
  readonly property string updatedAt: state.updated_at || ""
  readonly property string agentLabel: state.agent_label || ""
  // "!" badge: true whenever the latest scan hasn't been opened yet — e.g.
  // the timer fired overnight or the user just logged in and hasn't
  // clicked the bar icon since. Compares timestamps rather than ids so it
  // doesn't care whether the new scan actually changed anything.
  readonly property string lastViewedAt: viewed.viewed_at || ""
  readonly property bool hasUnseen: root.updatedAt !== "" && root.updatedAt !== root.lastViewedAt

  function markViewed() {
    if (root.updatedAt === "") return
    var dir = Quickshell.env("HOME") + "/.local/state/omarchy-arxiv-scanner"
    var file = dir + "/last_viewed.json"
    var json = JSON.stringify({ viewed_at: root.updatedAt })
    // Not a plain `> file` redirect onto a predictable path: that follows
    // a pre-planted symlink there and truncates whatever it points at
    // instead of writing last_viewed.json. mktemp's random name plus
    // atomic create-and-open, then mv to replace the destination entry
    // itself (rather than writing through it), closes that off — same
    // pattern as install.sh/save-settings.sh's temp-file writes.
    root.run(
      "mkdir -p " + root.shQuote(dir) +
      " && tmp=$(mktemp " + root.shQuote(dir + "/.last_viewed.json.XXXXXX") + ")" +
      " && printf '%s' " + root.shQuote(json) + " > \"$tmp\"" +
      " && mv -f \"$tmp\" " + root.shQuote(file))
  }

  readonly property string category: config.category || "quant-ph"
  readonly property var interestAreas: config.interestAreas || []
  readonly property var watchedAuthors: config.watchedAuthors || []
  readonly property int maxAreaMatches: config.maxAreaMatches !== undefined ? config.maxAreaMatches : 3
  readonly property int maxWatchedMatches: config.maxWatchedMatches !== undefined ? config.maxWatchedMatches : 3
  // null/undefined = no per-author cap — a global top-N-most-recent
  // ceiling with several watched authors otherwise lets whichever one
  // publishes most often or most recently crowd the rest out of their own
  // slots, rather than guaranteeing each watched author some visibility.
  readonly property var maxWatchedPerAuthor: (config.maxWatchedPerAuthor !== undefined && config.maxWatchedPerAuthor !== null) ? config.maxWatchedPerAuthor : null
  readonly property string pollTime: config.pollTime || "07:00"
  readonly property string aiBackend: config.aiBackend || "auto"
  readonly property string codexModel: config.codexModel || ""

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
}
