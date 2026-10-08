import QtQuick
import qs.Ui
import qs.Commons

// The arXiv settings form (category, interests, authors, limits, AI backend,
// Save). Shared by the bar popup (inline, inside View.qml) and the hub card's
// own pop-out window (SettingsWindow.qml). `backend` (Backend.qml) supplies
// the current values and runs the save/check scripts.
Column {
  id: form

  required property var backend
  property color fg: Color.popups.text
  property string ff: Style.font.family

  width: parent ? parent.width : 0
  spacing: Style.space(8)

  // Copies the saved values into the fields. Call each time the form opens.
  function load() {
    categoryField.text = backend.category
    interestsField.text = backend.interestAreas.join(", ")
    authorsField.text = backend.watchedAuthors.join(", ")
    maxAreaField.text = String(backend.maxAreaMatches)
    maxWatchedField.text = String(backend.maxWatchedMatches)
    maxWatchedPerAuthorField.text = backend.maxWatchedPerAuthor !== null ? String(backend.maxWatchedPerAuthor) : ""
    pollTimeField.text = backend.pollTime
    aiBackendDropdown.value = backend.aiBackend
    codexModelField.text = backend.codexModel
    backend.saveStatus = ""
  }

  Text {
    textFormat: Text.PlainText
    text: "arXiv category (e.g. quant-ph, cs.CR, cs.LG — matches https://arxiv.org/list/<category>/new)"
    color: Qt.darker(form.fg, 1.3)
    font.family: form.ff
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
    color: Qt.darker(form.fg, 1.3)
    font.family: form.ff
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
    color: Qt.darker(form.fg, 1.3)
    font.family: form.ff
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
      text: backend.checkingAuthors ? "Checking…" : "Check authors"
      foreground: form.fg
      enabled: !backend.checkingAuthors && authorsField.text.trim() !== ""
      onClicked: {
        backend.checkingAuthors = true
        backend.run(backend.pluginDir + "bin/check-authors.py --authors "
          + backend.shQuote(authorsField.text) + " --category " + backend.shQuote(categoryField.text || "quant-ph"))
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: backend.checkingAuthors
    text: "Querying arXiv per author (a few seconds each, be patient)…"
    color: Qt.darker(form.fg, 1.4)
    font.family: form.ff
    font.pixelSize: Style.font.caption
    font.italic: true
  }

  Column {
    width: parent.width
    spacing: Style.space(6)
    visible: !backend.checkingAuthors && backend.authorCheckResults.length > 0

    Repeater {
      model: backend.authorCheckResults

      Column {
        required property var modelData
        width: parent.width
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: (modelData.found ? "✓ " : "✗ ") + modelData.name
            + (modelData.found
              ? " — " + modelData.total_count + " paper(s) in " + backend.category
                + (modelData.cached
                  ? " (already verified — skipped re-checking)"
                  : (modelData.recent && modelData.recent.length > 0 ? ", " + modelData.recent.length + " in the last 30 days" : ", none in the last 30 days"))
              : " — no papers found in " + backend.category + ". Check spelling (arXiv wants \"Firstname Lastname\") or that they publish in this category.")
          color: modelData.found ? Qt.darker(form.fg, 1.2) : Color.urgent
          font.family: form.ff
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
      width: (parent.width - Style.space(36)) / 4
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: "Max relevant"
        color: Qt.darker(form.fg, 1.3)
        font.family: form.ff
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
      width: (parent.width - Style.space(36)) / 4
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: "Max watched"
        color: Qt.darker(form.fg, 1.3)
        font.family: form.ff
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
      width: (parent.width - Style.space(36)) / 4
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: "Per author (blank = no cap)"
        color: Qt.darker(form.fg, 1.3)
        font.family: form.ff
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
      TextField {
        id: maxWatchedPerAuthorField
        width: parent.width
        placeholderText: "no cap"
        validator: IntValidator { bottom: 1; top: 20 }
      }
    }

    Column {
      width: (parent.width - Style.space(36)) / 4
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: "Scan time (24h)"
        color: Qt.darker(form.fg, 1.3)
        font.family: form.ff
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
    width: parent.width
    spacing: Style.space(12)

    Column {
      width: (parent.width - Style.space(12)) / 2
      spacing: Style.space(4)
      Dropdown {
        id: aiBackendDropdown
        width: parent.width
        label: "AI backend"
        foreground: form.fg
        options: [
          { value: "auto", label: "Auto (first signed-in agent found)" },
          { value: "claude", label: "Claude Code" },
          { value: "codex", label: "Codex" }
        ]
      }
    }

    Column {
      width: (parent.width - Style.space(12)) / 2
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: "Codex model (blank = codex's default)"
        color: Qt.darker(form.fg, 1.3)
        font.family: form.ff
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
      TextField {
        id: codexModelField
        width: parent.width
        placeholderText: "e.g. openai/gpt-5-codex"
      }
    }
  }

  Row {
    spacing: Style.space(8)

    Button {
      text: "Save"
      foreground: form.fg
      onClicked: {
        {
          var cmd = backend.pluginDir + "bin/save-settings.sh"
            + " --category " + backend.shQuote(categoryField.text)
            + " --interests " + backend.shQuote(interestsField.text)
            + " --authors " + backend.shQuote(authorsField.text)
            + " --max-area " + backend.shQuote(maxAreaField.text || "3")
            + " --max-watched " + backend.shQuote(maxWatchedField.text || "3")
            + " --max-watched-per-author " + backend.shQuote(maxWatchedPerAuthorField.text)
            + " --poll-time " + backend.shQuote(pollTimeField.text || "07:00")
            + " --ai-backend " + backend.shQuote(aiBackendDropdown.value || "auto")
            + " --codex-model " + backend.shQuote(codexModelField.text)
          backend.run(cmd)
        }
        backend.saveStatus = "Saved — applies on the next scan (scan time takes effect immediately)."
      }
    }
  }

  Text {
    visible: backend.saveStatus !== ""
    textFormat: Text.PlainText
    text: backend.saveStatus
    color: Qt.darker(form.fg, 1.3)
    font.family: form.ff
    font.pixelSize: Style.font.caption
    width: parent.width
    wrapMode: Text.WordWrap
  }
}
