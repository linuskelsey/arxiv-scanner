#!/usr/bin/env bash
# Persists all user-configurable settings for the arxiv-quantum plugin and,
# if the poll time changed, regenerates the systemd --user timer to match.
# Invoked from the bar widget's Settings panel via `bar.run(...)`.
#
# Usage: save-settings.sh --category quant-ph --interests "Area one, Area two" \
#          --authors "Author One, Author Two" --max-area 3 --max-watched 3 \
#          --poll-time 07:00

set -euo pipefail

CONFIG_DIR="$HOME/.config/omarchy-arxiv-quantum"
CONFIG_FILE="$CONFIG_DIR/config.json"
TIMER_FILE="$HOME/.config/systemd/user/omarchy-arxiv-quantum.timer"

CATEGORY="quant-ph"
INTERESTS=""
AUTHORS=""
MAX_AREA="3"
MAX_WATCHED="3"
POLL_TIME="07:00"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --category) CATEGORY="$2"; shift 2 ;;
    --interests) INTERESTS="$2"; shift 2 ;;
    --authors) AUTHORS="$2"; shift 2 ;;
    --max-area) MAX_AREA="$2"; shift 2 ;;
    --max-watched) MAX_WATCHED="$2"; shift 2 ;;
    --poll-time) POLL_TIME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$CONFIG_DIR"

jq -n \
  --arg category "$CATEGORY" \
  --arg interests "$INTERESTS" \
  --arg authors "$AUTHORS" \
  --arg pollTime "$POLL_TIME" \
  --argjson maxArea "${MAX_AREA:-3}" \
  --argjson maxWatched "${MAX_WATCHED:-3}" \
  '
  ($interests | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $interestList
  | ($authors | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $authorList
  | {
      category: ($category | gsub("^\\s+|\\s+$"; "")),
      interestAreas: $interestList,
      watchedAuthors: $authorList,
      maxAreaMatches: $maxArea,
      maxWatchedMatches: $maxWatched,
      pollTime: $pollTime
    }
  ' > "$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

# Only touch the timer if poll time is a valid HH:MM and actually differs —
# a systemctl restart on every settings save (even unrelated ones) would
# reset the timer's elapse countdown for no reason.
if [[ "$POLL_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] && [[ -f "$TIMER_FILE" ]]; then
  CURRENT="$(grep -oP '(?<=OnCalendar=\*-\*-\* )\d{2}:\d{2}(?=:00)' "$TIMER_FILE" || true)"
  if [[ "$CURRENT" != "$POLL_TIME" ]]; then
    sed -i "s/^OnCalendar=.*/OnCalendar=*-*-* ${POLL_TIME}:00/" "$TIMER_FILE"
    systemctl --user daemon-reload
    systemctl --user restart omarchy-arxiv-quantum.timer
  fi
fi
