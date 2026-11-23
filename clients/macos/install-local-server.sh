#!/bin/bash
# Keep the local Greyline Hub server running on this Mac (LaunchAgent).
# Usage: ./install-local-server.sh /path/to/greyline-hub [port]
#
# Run this from Terminal.app on the Mac, not over SSH. The gui/ launchd
# domain only exists in a graphical login session.

set -euo pipefail

LABEL="com.greylinehub.server"
ROOT="${1:-}"
PORT="${2:-8754}"

if [ -z "$ROOT" ] || [ ! -f "$ROOT/greyline-hub" ]; then
  echo "usage: $0 /path/to/greyline-hub [port]" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "port must be 1-65535, got: $PORT" >&2
  exit 1
fi

ROOT="$(cd "$ROOT" && pwd)"
# LaunchAgents do not see a shell PATH. Prefer Homebrew, which is python.org
# builds such as 3.14 on Apple Silicon and Intel.
if [ -x /opt/homebrew/bin/python3 ]; then
  PYTHON="/opt/homebrew/bin/python3"
elif [ -x /usr/local/bin/python3 ]; then
  PYTHON="/usr/local/bin/python3"
else
  PYTHON="$(command -v python3 || true)"
fi
if [ -z "$PYTHON" ]; then
  echo "python3 was not found. Install it with Homebrew or the python.org installer." >&2
  exit 1
fi

if [ ! -f "$ROOT/config.json" ]; then
  cp "$ROOT/config.example.json" "$ROOT/config.json"
  echo "Created $ROOT/config.json from the example."
fi
if [ "$#" -ge 2 ]; then
  "$PYTHON" - "$ROOT" "$PORT" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from greyline_hub.config import strip_json_comments
from greyline_hub.config_api import save_config_file
path = Path(sys.argv[1]) / "config.json"
raw = json.loads(strip_json_comments(path.read_text(encoding="utf-8")))
raw.setdefault("server", {})["port"] = int(sys.argv[2])
raw["server"].setdefault("enabled", True)
save_config_file(path, raw)
PY
fi
PORT="$("$PYTHON" - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from greyline_hub.config import load_config
cfg, _, _ = load_config(Path(sys.argv[1]) / "config.json")
port = int(cfg["server"]["port"] or 8754)
if port < 1 or port > 65535:
    port = 8754
print(port)
PY
)"

UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
TARGET="${DOMAIN}/${LABEL}"
AGENTS="${HOME}/Library/LaunchAgents"
LOG="${HOME}/Library/Logs/GreylineHub.log"
PLIST="${AGENTS}/${LABEL}.plist"

xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

domain_ready() {
  launchctl print "$DOMAIN" >/dev/null 2>&1
}

service_loaded() {
  launchctl print "$TARGET" >/dev/null 2>&1
}

wait_until_unloaded() {
  local i
  for ((i = 1; i <= 20; i++)); do
    service_loaded || return 0
    sleep 0.25
  done
  return 1
}

port_answers() {
  "$PYTHON" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/api/health', timeout=1).read()" >/dev/null 2>&1
}

job_running() {
  launchctl print "$TARGET" 2>/dev/null | grep -q "state = running"
}

mkdir -p "$AGENTS" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$PYTHON")</string>
    <string>$(xml_escape "$ROOT")/greyline-hub</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$ROOT")</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LOG")</string>
</dict>
</plist>
EOF

if ! domain_ready; then
  cat >&2 <<EOF
No graphical login session is available (launchd domain ${DOMAIN}).
This is what \`Bootstrap failed: 125: Domain does not support specified action\`
means. It happens over SSH, and before anyone has logged in on the console.

The plist is written:
  ${PLIST}
Open Terminal.app on the Mac itself, in the logged-in account, and run:
  $(printf '%q' "$0") $(printf '%q' "$ROOT") ${PORT}
EOF
  exit 1
fi

if service_loaded; then
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  if ! wait_until_unloaded; then
    echo "warning: ${TARGET} is still registered after bootout; loading anyway" >&2
  fi
fi

bootstrapped=0
bootstrap_err=""
for ((i = 1; i <= 8; i++)); do
  if bootstrap_err="$(launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1)"; then
    bootstrapped=1
    break
  fi
  # bootout can still be settling. Wait, then try again.
  sleep 0.4
done

if [ "$bootstrapped" -ne 1 ]; then
  echo "launchctl bootstrap failed (${bootstrap_err:-unknown}). Trying launchctl load -w." >&2
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  wait_until_unloaded || true
  if ! load_err="$(launchctl load -w "$PLIST" 2>&1)"; then
    cat >&2 <<EOF
Could not load ${LABEL}.
  bootstrap: ${bootstrap_err:-failed}
  load -w: ${load_err:-failed}
If this shell is SSH, open Terminal.app on the Mac and run the script again.
The plist is at ${PLIST}
Agent log: ${LOG}
EOF
    exit 1
  fi
fi

launchctl enable "$TARGET" >/dev/null 2>&1 || true
launchctl kickstart -k "$TARGET" >/dev/null 2>&1 || true

echo "Waiting for http://127.0.0.1:${PORT}/api/health"
for ((i = 1; i <= 40; i++)); do
  if port_answers && job_running; then
    echo "LaunchAgent is running. Shack page: http://127.0.0.1:${PORT}/"
    echo "Configuration: http://127.0.0.1:${PORT}/config/"
    echo "Log: ${LOG}"
    exit 0
  fi
  sleep 0.5
done

if port_answers; then
  echo "Something answered on port ${PORT}, but the LaunchAgent is not staying running." >&2
else
  echo "The agent was loaded, but nothing answered on port ${PORT}." >&2
fi
echo "Last lines of ${LOG}:" >&2
if [ -f "$LOG" ]; then
  tail -n 40 "$LOG" >&2 || true
else
  echo "(no log file yet)" >&2
fi
exit 1
