#!/bin/bash
# Remove the idle saver, launcher, and XScreenSaver command. The server service stays.
set -euo pipefail
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
AUTO_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
systemctl --user disable --now greyline-hub-idle.service 2>/dev/null || true
rm -f "$UNIT_DIR/greyline-hub-idle.service"
rm -f "$APP_DIR/greyline-hub.desktop"
rm -f "$AUTO_DIR/greyline-hub-tray.desktop"
rm -f "$HOME/.local/bin/greyline-hub-xscreensaver"
rm -f "$HOME/.local/share/xscreensaver/config/greyline-hub.xml"
systemctl --user daemon-reload || true
echo "Removed the Greyline Hub idle saver and launcher."
echo "The programs: line in ~/.xscreensaver, if you added one, is left for you to delete."
