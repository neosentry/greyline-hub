#!/bin/bash
# Stop and remove the Greyline Hub user service. Leaves config.json in place.
set -euo pipefail
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
systemctl --user disable --now greyline-hub.service 2>/dev/null || true
rm -f "$UNIT_DIR/greyline-hub.service"
systemctl --user daemon-reload || true
echo "Removed greyline-hub.service"
