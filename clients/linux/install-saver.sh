#!/bin/bash
# Install the GNOME/Wayland idle saver, a launcher, and an XScreenSaver command.
# Usage: ./install-saver.sh [/path/to/greyline-hub]
#
# Ubuntu 26.04 GNOME on Wayland is the target. Packages are GTK 4 and WebKitGTK 6.
# X11 (xprintidle, xscreensaver) is installed when those packages exist, and is optional.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${1:-$HERE/../..}" && pwd)"
PYTHON="/usr/bin/python3"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
AUTO_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
BIN_DIR="$HOME/.local/bin"

if [ ! -f "$ROOT/greyline-hub" ]; then
  echo "usage: $0 [/path/to/greyline-hub]" >&2
  exit 1
fi
if [ ! -x "$PYTHON" ]; then
  PYTHON="$(command -v python3 || true)"
fi

if [ "${GREYLINE_SKIP_APT:-}" != "1" ] && command -v apt-get >/dev/null 2>&1; then
  echo "Installing GTK 4 / WebKitGTK 6 and session tools (sudo apt-get)..."
  sudo apt-get update
  sudo apt-get install -y \
    python3 \
    python3-gi \
    gir1.2-gtk-4.0 \
    gir1.2-webkit-6.0 \
    libglib2.0-bin \
    xdg-utils
  # Tray icon and X11 idle. Missing names on a minimal image are not fatal.
  sudo apt-get install -y gir1.2-ayatanaappindicator3-0.1 gnome-shell-extension-appindicator || true
  sudo apt-get install -y xprintidle xscreensaver || true
fi

mkdir -p "$UNIT_DIR" "$APP_DIR" "$AUTO_DIR" "$BIN_DIR"
cat > "$UNIT_DIR/greyline-hub-idle.service" <<EOF
[Unit]
Description=Greyline Hub idle dashboard
After=graphical-session.target greyline-hub.service
PartOf=graphical-session.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=$PYTHON $ROOT/greyline-hub idle
Restart=on-failure
RestartSec=5
PassEnvironment=DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP

[Install]
WantedBy=graphical-session.target
EOF

cat > "$BIN_DIR/greyline-hub-xscreensaver" <<EOF
#!/bin/sh
# XScreenSaver runs this and kills it on input. GNOME/Wayland uses the idle service instead.
cd "$ROOT"
exec "$PYTHON" "$ROOT/greyline-hub" kiosk --exit-on-input "\$@"
EOF
chmod 755 "$BIN_DIR/greyline-hub-xscreensaver"

DESKTOP="$APP_DIR/greyline-hub.desktop"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Name=Greyline Hub
Comment=Dashboard server, configuration, and idle screen
Exec=$PYTHON $ROOT/greyline-hub tray
Icon=video-display
Terminal=false
Type=Application
Categories=Utility;HamRadio;
StartupNotify=false
EOF

cat > "$AUTO_DIR/greyline-hub-tray.desktop" <<EOF
[Desktop Entry]
Name=Greyline Hub
Comment=Status icon for the dashboard server
Exec=env GREYLINE_TRAY_AUTOSTART=1 $PYTHON $ROOT/greyline-hub tray --autostart
Icon=video-display
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
EOF

mkdir -p "$HOME/.local/share/xscreensaver/config"
cp "$HERE/xscreensaver/greyline-hub.xml" "$HOME/.local/share/xscreensaver/config/greyline-hub.xml"
if [ -f "$HOME/.xscreensaver" ]; then
  "$PYTHON" - "$HOME/.xscreensaver" "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
from greyline_hub.linux_saver import insert_xscreensaver_program
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
updated, changed = insert_xscreensaver_program(text, "greyline-hub-xscreensaver --root")
if changed:
    path.write_text(updated, encoding="utf-8")
    print(f"Added Greyline Hub to {path}")
else:
    print(f"No programs: list changed in {path} (already present, or there is no programs: line).")
PY
else
  echo "No ~/.xscreensaver yet. After you run xscreensaver-demo once, re-run this script"
  echo "or add this line under programs: in ~/.xscreensaver:"
  echo "    greyline-hub-xscreensaver --root \\n\\"
fi

systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS || true
systemctl --user daemon-reload
systemctl --user enable --now greyline-hub-idle.service

echo
echo "Idle saver: greyline-hub-idle.service"
echo "Launcher:   $DESKTOP"
echo "Before relying on it, set GNOME Blank Screen longer than linux.idle_minutes"
echo "(default 5), or turn Blank Screen off:"
echo "  gsettings set org.gnome.desktop.session idle-delay 0"
echo "Test now:   $PYTHON $ROOT/greyline-hub kiosk --exit-on-input"
systemctl --user --no-pager --full status greyline-hub-idle.service || true
