#!/usr/bin/env bash
# Reverses install.sh: stops and removes the systemd units. Does NOT delete
# your config, state, or the plugin directory itself — see the README's
# Uninstall section if you want those gone too.
set -euo pipefail

SYSTEMD_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now omarchy-arxiv-scanner.timer 2>/dev/null || true
rm -f "$SYSTEMD_DIR/omarchy-arxiv-scanner.service" "$SYSTEMD_DIR/omarchy-arxiv-scanner.timer"
systemctl --user daemon-reload

echo "Timer stopped and unit files removed."
echo "Still on disk (delete manually if you want a clean uninstall):"
echo "  ~/.config/omarchy-arxiv-scanner/       (your config)"
echo "  ~/.local/state/omarchy-arxiv-scanner/  (scan history/state)"
echo "  $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)  (this plugin directory)"
echo "Restart the shell afterward so the bar icon disappears: omarchy-restart-shell"
