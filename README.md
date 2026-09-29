# arXiv Scanner

An [Omarchy](https://omarchy.org) bar-widget plugin that scans arXiv's new
submissions in a category of your choice (defaults to `quant-ph`) every
morning, uses [Claude Code](https://claude.com/claude-code) to rank them
against your interest areas and write a one-sentence summary, and separately
flags anything by authors you're specifically watching. Matches show up as a
badge on the bar and a desktop notification; click the badge for the full
list.

## Features

- Daily scan via a systemd `--user` timer (default 07:30, configurable)
- Claude-ranked relevance against a list of interest areas you define
- A separate "watched authors" list — their new papers always show up,
  independent of the relevance ranking
- One-sentence Claude-generated summary per paper, collapsed by default,
  click to expand (and open the paper on arXiv from there)
- Bar badge shows an unread count, with a `!` prefix if the latest scan
  hasn't been opened yet
- "Scan now" and a "Check authors" tool (see how many recent papers a
  watched author has, useful for catching name/spelling issues) from the
  widget's Settings panel — no config file editing required day-to-day

## Requirements

- [Omarchy](https://omarchy.org) with its Quickshell-based bar
- `python3`
- `jq` (used by the settings-save script)
- [`claude`](https://claude.com/claude-code) on `PATH` and logged in — used
  headlessly (`claude -p`) for ranking and summarizing; without it the
  widget falls back to a naive first-sentence trim, which still works but
  won't do relevance filtering
- `omarchy` CLI for desktop notifications (present by default on Omarchy;
  notifications just no-op without it)

## Install

```bash
git clone <this-repo-url> ~/.config/omarchy/plugins/prometheus.arxiv-quantum
~/.config/omarchy/plugins/prometheus.arxiv-quantum/install.sh
```

`install.sh` is safe to re-run. It:

- Writes a default `~/.config/omarchy-arxiv-quantum/config.json` if one
  doesn't already exist (never overwrites an existing one)
- Installs and enables the `omarchy-arxiv-quantum.timer` systemd user unit
- Warns (but doesn't fail) if `python3`, `jq`, or `claude` are missing

If the bar icon doesn't appear afterward, restart the shell:
`omarchy-restart-shell`.

## Configuration

Day-to-day, use the widget's own Settings panel (click the bar badge →
Settings): category, interest areas, watched authors, max matches shown per
section, and scan time all live there and take effect immediately (scan
time) or on the next scan (everything else).

For reference, `~/.config/omarchy-arxiv-quantum/config.json` looks like:

```json
{
  "category": "quant-ph",
  "interestAreas": ["whatever subfields or topics you care about"],
  "watchedAuthors": ["Jane Doe"],
  "maxAreaMatches": 3,
  "maxWatchedMatches": 3,
  "pollTime": "07:30"
}
```

`category` matches whatever you'd put in an arXiv listing URL
(`https://arxiv.org/list/<category>/new`) — `quant-ph`, `cs.CR`, `cs.LG`,
etc.

## How it works

`bin/poll.py` fetches arXiv's RSS feed for the configured category, sends
the day's new submissions to Claude in one batched call for relevance
ranking + summaries, separately checks every candidate's author list
against `watchedAuthors`, and writes the combined result to
`~/.local/state/omarchy-arxiv-quantum/state.json`, which the bar widget
(`BarWidget.qml`) reads and renders. `bin/check-authors.py` is a standalone
on-demand lookup (from the Settings panel) for sanity-checking a watched
author's name against arXiv. Nothing in the QML talks to the network or to
Claude directly — it only reads state files and shells out via `bar.run(...)`
for actions (scan now, check authors, save settings).

## License

MIT — see [LICENSE](LICENSE).
