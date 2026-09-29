#!/usr/bin/env bash
# Reverses install.sh: stops and removes the systemd units. Does NOT delete
# your config, state, or the plugin directory itself — see the README's
# Uninstall section if you want those gone too.
set -euo pipefail

SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_DEST="$SYSTEMD_DIR/omarchy-arxiv-scanner.service"
TIMER_DEST="$SYSTEMD_DIR/omarchy-arxiv-scanner.timer"

# Same-named units at these paths might not be ours — don't disable, stop,
# or delete anything install.sh didn't actually put there. Both shipped
# unit files carry this marker comment.
MARKER="# Managed-By: prometheus.arxiv-scanner"
is_ours() { [[ -f "$1" ]] && grep -qF "$MARKER" "$1"; }

if is_ours "$TIMER_DEST"; then
  systemctl --user disable --now omarchy-arxiv-scanner.timer 2>/dev/null || true
  rm -f "$TIMER_DEST"
else
  echo "No timer at $TIMER_DEST installed by this plugin — nothing to remove there." >&2
fi

if is_ours "$SERVICE_DEST"; then
  rm -f "$SERVICE_DEST"
else
  echo "No service at $SERVICE_DEST installed by this plugin — nothing to remove there." >&2
fi

systemctl --user daemon-reload

echo "Timer stopped and unit files removed."
echo "Still on disk (delete manually if you want a clean uninstall):"
echo "  ~/.config/omarchy-arxiv-scanner/       (your config)"
echo "  ~/.local/state/omarchy-arxiv-scanner/  (scan history/state)"
echo "  $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)  (this plugin directory)"
echo "Restart the shell afterward so the bar icon disappears: omarchy-restart-shell"
