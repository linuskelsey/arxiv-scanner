#!/usr/bin/env bash
# Persists all user-configurable settings for the arxiv-scanner plugin and,
# if the poll time changed, regenerates the systemd --user timer to match.
# Invoked from the bar widget's Settings panel via `bar.run(...)`.
#
# Usage: save-settings.sh --category quant-ph --interests "Area one, Area two" \
#          --authors "Author One, Author Two" --max-area 3 --max-watched 3 \
#          --max-watched-per-author 2 --poll-time 07:00
# --max-watched-per-author may be empty (no per-author cap).

set -euo pipefail

CONFIG_DIR="$HOME/.config/omarchy-arxiv-scanner"
CONFIG_FILE="$CONFIG_DIR/config.json"
TIMER_FILE="$HOME/.config/systemd/user/omarchy-arxiv-scanner.timer"

# Same-named unit at that path might not be ours — install.sh already
# checks this before touching it; this script edits the timer in place too
# (below) and needs the same guard, or a foreign unit could be altered by
# the Settings panel.
MARKER="# Managed-By: prometheus.arxiv-scanner"
is_ours() { [[ -f "$1" ]] && grep -qF "$MARKER" "$1"; }

CATEGORY="quant-ph"
INTERESTS=""
AUTHORS=""
MAX_AREA="3"
MAX_WATCHED="3"
MAX_WATCHED_PER_AUTHOR=""
POLL_TIME="07:00"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --category) CATEGORY="$2"; shift 2 ;;
    --interests) INTERESTS="$2"; shift 2 ;;
    --authors) AUTHORS="$2"; shift 2 ;;
    --max-area) MAX_AREA="$2"; shift 2 ;;
    --max-watched) MAX_WATCHED="$2"; shift 2 ;;
    --max-watched-per-author) MAX_WATCHED_PER_AUTHOR="$2"; shift 2 ;;
    --poll-time) POLL_TIME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$CONFIG_DIR"

# mktemp, not a predictable "$CONFIG_FILE.tmp" — a fixed temp-file name in a
# user-writable directory can be pre-planted as a symlink, so writing
# through it clobbers whatever that symlink points at instead of just
# CONFIG_FILE. mktemp's random name plus atomic create-and-open closes that.
TMP_FILE="$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

jq -n \
  --arg category "$CATEGORY" \
  --arg interests "$INTERESTS" \
  --arg authors "$AUTHORS" \
  --arg pollTime "$POLL_TIME" \
  --arg maxPerAuthor "$MAX_WATCHED_PER_AUTHOR" \
  --argjson maxArea "${MAX_AREA:-3}" \
  --argjson maxWatched "${MAX_WATCHED:-3}" \
  '
  ($interests | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $interestList
  | ($authors | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $authorList
  | ($maxPerAuthor | gsub("^\\s+|\\s+$"; "")) as $maxPerAuthorTrimmed
  | {
      category: ($category | gsub("^\\s+|\\s+$"; "")),
      interestAreas: $interestList,
      watchedAuthors: $authorList,
      maxAreaMatches: $maxArea,
      maxWatchedMatches: $maxWatched,
      maxWatchedPerAuthor: (if ($maxPerAuthorTrimmed | length) > 0 then ($maxPerAuthorTrimmed | tonumber) else null end),
      pollTime: $pollTime
    }
  ' > "$TMP_FILE"
mv -f "$TMP_FILE" "$CONFIG_FILE"

# Only touch the timer if poll time is a valid HH:MM and actually differs —
# a systemctl restart on every settings save (even unrelated ones) would
# reset the timer's elapse countdown for no reason.
if [[ "$POLL_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] && is_ours "$TIMER_FILE"; then
  CURRENT="$(grep -oP '(?<=OnCalendar=\*-\*-\* )\d{2}:\d{2}(?=:00)' "$TIMER_FILE" || true)"
  if [[ "$CURRENT" != "$POLL_TIME" ]]; then
    sed -i "s/^OnCalendar=.*/OnCalendar=*-*-* ${POLL_TIME}:00/" "$TIMER_FILE"
    systemctl --user daemon-reload
    systemctl --user restart omarchy-arxiv-scanner.timer
  fi
fi
