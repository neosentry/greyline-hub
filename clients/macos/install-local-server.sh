#!/bin/bash
# Keep the local Greyline Hub server running on this Mac (LaunchAgent).
# The screensaver will use it when the home server does not answer.
# Usage: ./install-local-server.sh /path/to/greyline-hub [port]

set -euo pipefail
ROOT="${1:-}"
PORT="${2:-8754}"
if [ -z "$ROOT" ] || [ ! -f "$ROOT/greyline-hub" ]; then
  echo "usage: $0 /path/to/greyline-hub [port]" >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd)"
PYTHON="$(command -v python3)"
HOME_DIR="$HOME"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
mkdir -p "$AGENTS" "$LOGS"
PLIST="$AGENTS/com.greylinehub.server.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.greylinehub.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON}</string>
    <string>${ROOT}/greyline-hub</string>
    <string>--port</string>
    <string>${PORT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${ROOT}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME_DIR}/Library/Logs/GreylineHub.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME_DIR}/Library/Logs/GreylineHub.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/com.greylinehub.server" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/com.greylinehub.server"
launchctl kickstart -k "gui/$(id -u)/com.greylinehub.server"
echo "LaunchAgent installed. Dashboard: http://127.0.0.1:${PORT}/"
echo "Log: $HOME/Library/Logs/GreylineHub.log"
