#!/bin/bash
# Install the Greyline Hub server as a systemd --user service.
# Usage: ./install-server.sh [/path/to/greyline-hub]
#
# Run this in a terminal on the Ubuntu desktop (GNOME session), not only over
# SSH, so the user systemd instance is the one that belongs to the login.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${1:-$HERE/../..}" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="${UNIT_DIR}/greyline-hub.service"
PYTHON="/usr/bin/python3"

if [ ! -f "$ROOT/greyline-hub" ]; then
  echo "usage: $0 [/path/to/greyline-hub]" >&2
  echo "greyline-hub launcher not found in $ROOT" >&2
  exit 1
fi
if [ ! -x "$PYTHON" ]; then
  PYTHON="$(command -v python3 || true)"
fi
if [ -z "$PYTHON" ]; then
  echo "python3 is not installed. sudo apt-get install -y python3" >&2
  exit 1
fi
if ! "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "python3 >= 3.9 is required. This interpreter:" >&2
  "$PYTHON" --version >&2 || true
  exit 1
fi

if [ ! -f "$ROOT/config.json" ]; then
  cp "$ROOT/config.example.json" "$ROOT/config.json"
  echo "Created $ROOT/config.json from the example."
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<EOF
[Unit]
Description=Greyline Hub dashboard server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=$PYTHON $ROOT/greyline-hub
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

if ! systemctl --user daemon-reload; then
  echo "systemctl --user failed. Open a terminal inside the GNOME session." >&2
  echo "The unit file is at $UNIT" >&2
  exit 1
fi
systemctl --user enable --now greyline-hub.service
sleep 1
PORT="$("$PYTHON" - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from greyline_hub.config import load_config
cfg, _, _ = load_config(Path(sys.argv[1]) / "config.json")
print(int(cfg["server"]["port"] or 8754))
PY
)"
echo "Server service: greyline-hub.service"
echo "Dashboard:     http://127.0.0.1:${PORT}/"
echo "Configuration: http://127.0.0.1:${PORT}/config/"
echo "Log:           journalctl --user -u greyline-hub.service -f"
systemctl --user --no-pager --full status greyline-hub.service || true
