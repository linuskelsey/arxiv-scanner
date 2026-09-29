#!/usr/bin/env bash
# Sets up scheduling and default config for the arxiv-quantum Omarchy plugin.
#
# Run this AFTER cloning this repo to its expected location:
#   git clone <this-repo-url> ~/.config/omarchy/plugins/prometheus.arxiv-quantum
#   ~/.config/omarchy/plugins/prometheus.arxiv-quantum/install.sh
#
# It only touches things outside the plugin directory itself: the systemd
# --user timer/service and the config.json the bar widget's Settings panel
# reads/writes. It's safe to re-run — an existing config.json is left alone.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/omarchy-arxiv-quantum"
SYSTEMD_DIR="$HOME/.config/systemd/user"

echo "Installing arxiv-quantum plugin from $PLUGIN_DIR"

missing=()
for cmd in python3 jq claude; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Warning: missing dependencies: ${missing[*]}" >&2
  echo "  python3, jq — required for polling and settings" >&2
  echo "  claude      — Claude Code CLI, required for classification and summaries" >&2
fi
command -v omarchy >/dev/null 2>&1 || echo "Note: 'omarchy' command not found — desktop notifications on match will silently no-op. Fine if you're not running Omarchy's shell." >&2

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  cp "$PLUGIN_DIR/config.example.json" "$CONFIG_DIR/config.json"
  echo "Wrote default config to $CONFIG_DIR/config.json — edit interest areas and watched authors there, or from the bar widget's Settings panel."
else
  echo "Existing config found at $CONFIG_DIR/config.json — leaving it alone."
fi

mkdir -p "$SYSTEMD_DIR"
cp "$PLUGIN_DIR/systemd/omarchy-arxiv-quantum.service" "$SYSTEMD_DIR/"
cp "$PLUGIN_DIR/systemd/omarchy-arxiv-quantum.timer" "$SYSTEMD_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now omarchy-arxiv-quantum.timer

echo "Done. Timer enabled — first automatic scan runs at the next scheduled time (07:30 by default, or use 'Scan now' in the widget right away)."
echo "If the bar icon doesn't show up yet, restart the shell: omarchy-restart-shell"
