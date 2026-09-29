#!/usr/bin/env bash
# Sets up scheduling and default config for the arxiv-scanner Omarchy plugin.
#
# Run this AFTER cloning this repo to its expected location:
#   git clone <this-repo-url> ~/.config/omarchy/plugins/prometheus.arxiv-scanner
#   ~/.config/omarchy/plugins/prometheus.arxiv-scanner/install.sh
#
# It only touches things outside the plugin directory itself: the systemd
# --user timer/service and the config.json the bar widget's Settings panel
# reads/writes. It's safe to re-run — an existing config.json is left alone.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/omarchy-arxiv-scanner"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# Copies $1 to $2 via mktemp+mv in the destination directory rather than a
# direct `cp` onto a predictable path. A predictable destination can be
# pre-planted as a symlink; `cp` follows it and writes through to whatever
# it points at, `mv` replaces the directory entry itself atomically instead.
install_file_safe() {
  local src="$1" dest="$2" tmp
  tmp="$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")"
  cp "$src" "$tmp"
  mv -f "$tmp" "$dest"
}

# A same-named unit at the destination might not be ours — some other
# plugin's install, or something the user wrote by hand. Both shipped unit
# files carry this marker comment; only touch (overwrite, enable, remove)
# a unit that has it.
MARKER="# Managed-By: prometheus.arxiv-scanner"
is_ours() { [[ -f "$1" ]] && grep -qF "$MARKER" "$1"; }

echo "Installing arxiv-scanner plugin from $PLUGIN_DIR"

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
if [[ ! -e "$CONFIG_DIR/config.json" && ! -L "$CONFIG_DIR/config.json" ]]; then
  install_file_safe "$PLUGIN_DIR/config.example.json" "$CONFIG_DIR/config.json"
  echo "Wrote default config to $CONFIG_DIR/config.json — edit interest areas and watched authors there, or from the bar widget's Settings panel."
else
  echo "Existing config found at $CONFIG_DIR/config.json — leaving it alone."
fi

mkdir -p "$SYSTEMD_DIR"
SERVICE_DEST="$SYSTEMD_DIR/omarchy-arxiv-scanner.service"
TIMER_DEST="$SYSTEMD_DIR/omarchy-arxiv-scanner.timer"

# The .service is static (just invokes poll.py, never user-edited) so it's
# always safe to refresh — but only if whatever's currently at that path is
# ours (or nothing's there yet); never overwrite an unrelated same-named unit.
if [[ ! -e "$SERVICE_DEST" && ! -L "$SERVICE_DEST" ]] || is_ours "$SERVICE_DEST"; then
  install_file_safe "$PLUGIN_DIR/systemd/omarchy-arxiv-scanner.service" "$SERVICE_DEST"
else
  echo "Warning: $SERVICE_DEST already exists and wasn't installed by this plugin — leaving it alone. Scanning won't be scheduled until that's resolved." >&2
fi

# The .timer is different again: save-settings.sh rewrites its OnCalendar
# line whenever the Settings panel's scan-time field changes, so blindly
# overwriting an existing one on every install.sh re-run would silently
# discard that. Only install it if it's not already there.
if [[ ! -e "$TIMER_DEST" && ! -L "$TIMER_DEST" ]]; then
  install_file_safe "$PLUGIN_DIR/systemd/omarchy-arxiv-scanner.timer" "$TIMER_DEST"
elif is_ours "$TIMER_DEST"; then
  echo "Existing timer found at $TIMER_DEST — leaving it alone (it may hold a scan time you set via the widget's Settings panel)."
else
  echo "Warning: $TIMER_DEST already exists and wasn't installed by this plugin — leaving it alone and not enabling it." >&2
fi

systemctl --user daemon-reload

if is_ours "$SERVICE_DEST" && is_ours "$TIMER_DEST"; then
  systemctl --user enable --now omarchy-arxiv-scanner.timer
  echo "Done. Timer enabled — first automatic scan runs at the next scheduled time (07:30 by default, or use 'Scan now' in the widget right away)."
else
  echo "Skipped enabling the timer — resolve the unit-name conflict above, then re-run install.sh." >&2
fi

echo "If the bar icon doesn't show up yet, restart the shell: omarchy-restart-shell"
