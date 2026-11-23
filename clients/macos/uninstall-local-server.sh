#!/bin/bash
# Stop the Greyline Hub LaunchAgent and remove its plist.
# Usage: ./uninstall-local-server.sh

set -euo pipefail

LABEL="com.greylinehub.server"
UID_NUM="$(id -u)"
TARGET="gui/${UID_NUM}/${LABEL}"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG="${HOME}/Library/Logs/GreylineHub.log"

service_loaded() {
  launchctl print "$TARGET" >/dev/null 2>&1
}

if service_loaded; then
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  for ((i = 1; i <= 20; i++)); do
    service_loaded || break
    sleep 0.25
  done
fi

if [ -f "$PLIST" ]; then
  launchctl unload -w "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
fi

if service_loaded; then
  cat >&2 <<EOF
${TARGET} is still loaded. This shell may not be in the graphical session
(SSH cannot always bootout a gui agent). From Terminal.app on the Mac, run:
  launchctl bootout ${TARGET}
The plist has been removed, so it will not come back at the next login.
EOF
  exit 1
fi

echo "Removed ${LABEL}."
echo "The server log is still at ${LOG}"
