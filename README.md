# arXiv Scanner

An [Omarchy](https://omarchy.org) bar-widget plugin that scans arXiv's new
submissions in a category of your choice (defaults to `quant-ph`) every
morning, uses [Claude Code](https://claude.com/claude-code) to rank them
against your interest areas and write a one-sentence summary, and separately
flags anything by authors you're specifically watching. Matches show up as a
badge on the bar and a desktop notification; click the badge for the full
list.

## Features

- Daily scan via a systemd `--user` timer (default 07:30, configurable), plus
  a second timer that checks shortly after every login/boot for a scan
  that's over 24h stale (e.g. the laptop was off at 07:30) and catches up
  if so — a no-op otherwise, so it's safe to fire on every normal login
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
  headlessly (`claude -p`) for both relevance ranking and summarizing.
  **Relevance filtering has no fallback**: without `claude`, the "Recent
  papers of interest" column stays empty every scan. The separate watched
  authors list still works either way — its summaries just fall back to a
  naive first-sentence trim of the abstract instead of a Claude-written one
- `omarchy` CLI for desktop notifications (present by default on Omarchy;
  notifications just no-op without it)

## Install

> **Manual setup required.** If you're adding this through the Omarchy
> plugin marketplace's standard flow, that only places the plugin files in
> `~/.config/omarchy/plugins/` — it does not run `install.sh`. Scheduling
> (the daily scan) won't start until you run it yourself, once, as below.

```bash
git clone https://github.com/linuskelsey/arxiv-scanner.git ~/.config/omarchy/plugins/prometheus.arxiv-scanner
cd ~/.config/omarchy/plugins/prometheus.arxiv-scanner
# Pin to the last already-approved marketplace snapshot rather than a
# branch (which can move) or a tag (which, unlike a commit hash, can be
# force-moved to point elsewhere). This can never be the commit you're
# reading this file at — a commit can't embed its own resulting hash — so
# it intentionally trails whatever's currently under review by one step.
git checkout 1ee3a35da833b5c01f7b6e21055b2f5bfbbf48be
./install.sh
```

`install.sh` is safe to re-run. It never overwrites your existing config or a
timer whose scan time you've already customized. It:

- Writes a default `~/.config/omarchy-arxiv-scanner/config.json` if one
  doesn't already exist
- Installs and enables the `omarchy-arxiv-scanner.timer` systemd user unit
  (skipped if that unit file already exists, since the Settings panel edits
  it in place to store your chosen scan time)
- Warns (but doesn't fail) if `python3`, `jq`, or `claude` are missing

If the bar icon doesn't appear afterward, restart the shell:
`omarchy-restart-shell`.

## Upgrading from before the watched-candidates superset

If you're updating an existing install from a version before the
watched-authors list was backed by a persistent superset
(`watched_candidates.json`), run this once after pulling the update —
otherwise the first scan after upgrading recomputes `watched_matches` from
an empty superset and your currently-displayed watched-author papers
briefly disappear until fresh ones are found:

```bash
python3 -c "
import sys
sys.path.insert(0, '$HOME/.config/omarchy/plugins/prometheus.arxiv-scanner/bin')
import json, poll

state = json.loads(poll.STATE_FILE.read_text())
current = state.get('watched_matches', [])
config = poll.load_config()
watched = config['watchedAuthors']
for m in current:
    if 'matched_config_name' in m:
        continue
    ma = m.get('matched_author', '').lower()
    for name in watched:
        if name.lower() in ma or ma in name.lower():
            m['matched_config_name'] = name
            break

merged = poll.prune_watched_candidates(poll.merge_watched_matches(poll.load_watched_candidates(), current))
poll.write_watched_candidates(merged)
print(f'seeded watched_candidates.json with {len(merged)} entries')
"
```

This backfills `matched_config_name` (the field the new filtering logic
keys on) from each entry's `matched_author` by re-running the same
fuzzy name-matching `watched_author_matches()` itself uses, so nothing
that's already displayed gets silently dropped by the migration.

## Uninstall

```bash
~/.config/omarchy/plugins/prometheus.arxiv-scanner/uninstall.sh
```

This stops and removes the systemd timer/service. It deliberately leaves
your config, scan history, and the plugin directory itself in place — delete
these manually for a full clean removal:

```bash
rm -rf ~/.config/omarchy/plugins/prometheus.arxiv-scanner
rm -rf ~/.config/omarchy-arxiv-scanner
rm -rf ~/.local/state/omarchy-arxiv-scanner
```

Then restart the shell (`omarchy-restart-shell`) so the bar icon disappears.

## Configuration

Day-to-day, use the widget's own Settings panel (click the bar badge →
Settings): category, interest areas, watched authors, max matches shown per
section, and scan time all live there and take effect immediately (scan
time) or on the next scan (everything else).

For reference, `~/.config/omarchy-arxiv-scanner/config.json` looks like:

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
`~/.local/state/omarchy-arxiv-scanner/state.json`, which the bar widget
(`BarWidget.qml`) reads and renders. `bin/check-authors.py` is a standalone
on-demand lookup (from the Settings panel) for sanity-checking a watched
author's name against arXiv. Nothing in the QML talks to the network or to
Claude directly — it only reads state files and shells out via `bar.run(...)`
for actions (scan now, check authors, save settings).

Two systemd `--user` timers drive `poll.py`, both installed by `install.sh`:
the main `omarchy-arxiv-scanner.timer` (daily, at the configured scan time)
and `omarchy-arxiv-scanner-catchup.timer` (`OnStartupSec`, ~2 minutes after
every login/boot). The daily timer's own `Persistent=true` should already
re-run a missed 07:30 scan once your session starts again, but that relies
on session-lingering and systemd's own stamp-file bookkeeping working as
expected — the catch-up timer makes the same outcome deterministic instead:
it always fires shortly after login, and `poll.py --if-stale` (not the
timer) decides whether that's a real catch-up scan or a no-op, based on
`state.json`'s own `updated_at` (stale = missing or over 24h old).

## License

MIT — see [LICENSE](LICENSE).
