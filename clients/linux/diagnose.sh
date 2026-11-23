#!/bin/bash
# Print what the Ubuntu session can see: Wayland vs X11, idle backend, services, packages.
# Usage: ./diagnose.sh [/path/to/greyline-hub]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${1:-$HERE/../..}" && pwd)"
PYTHON="/usr/bin/python3"
if [ ! -x "$PYTHON" ]; then
  PYTHON="$(command -v python3 || true)"
fi

section() { printf '\n===== %s =====\n' "$1"; }

section "machine"
hostname 2>/dev/null || true
. /etc/os-release 2>/dev/null || true
printf '%s %s\n' "${NAME:-unknown}" "${VERSION:-}"
uname -sr
echo "user $(id -un) uid $(id -u)"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
echo "DISPLAY=${DISPLAY:-}"

section "python"
if [ -n "$PYTHON" ]; then
  echo "interpreter $PYTHON"
  "$PYTHON" --version || true
else
  echo "python3 not found"
fi

section "packages and tools"
for cmd in gdbus gsettings xprintidle chromium chromium-browser firefox systemctl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "present $cmd $(command -v "$cmd")"
  else
    echo "missing $cmd"
  fi
done
if [ -n "$PYTHON" ]; then
  "$PYTHON" - <<'PY' || true
import importlib.util
print("python ok")
try:
    import gi
    print("gi", getattr(gi, "__file__", "yes"))
except Exception as exc:
    print("gi missing", exc)
PY
fi

section "gnome blank screen"
if command -v gsettings >/dev/null 2>&1; then
  echo -n "org.gnome.desktop.session idle-delay = "
  gsettings get org.gnome.desktop.session idle-delay 2>&1 || true
  echo -n "org.gnome.desktop.screensaver lock-enabled = "
  gsettings get org.gnome.desktop.screensaver lock-enabled 2>&1 || true
  echo -n "org.gnome.desktop.screensaver lock-delay = "
  gsettings get org.gnome.desktop.screensaver lock-delay 2>&1 || true
else
  echo "gsettings not installed"
fi
echo "Blank Screen must be longer than Greyline idle minutes, or off (idle-delay 0)."

section "idle backend"
if [ -n "$PYTHON" ]; then
  "$PYTHON" - "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from greyline_hub.config import discover_config
from greyline_hub.linux_idle import gnome_blank_seconds, read_idle_ms, tool_set
from greyline_hub.linux_kiosk import available_renderers
from greyline_hub.linux_saver import blank_conflict, idle_plan, session_type
session = session_type()
tools = tool_set()
plan = idle_plan(session, tools)
print(f"session {session}")
print(f"tools {', '.join(sorted(tools)) or 'none'}")
print(f"plan {', '.join(plan) or 'none'}")
print(f"renderers {', '.join(sorted(available_renderers())) or 'none'}")
idle = read_idle_ms(plan) if plan else None
print(f"idle_ms {idle if idle is not None else 'unavailable'}")
try:
    cfg, path, _ = discover_config(None)
    print(f"config {path}")
    linux = cfg["linux"]
    print(f"idle_minutes {linux['idle_minutes']} renderer {linux['renderer']} display {linux['display']!r} page {linux['page']}")
    warning = blank_conflict(gnome_blank_seconds(), linux["idle_minutes"])
    if warning:
        print("WARNING", warning)
    else:
        print("gnome blank does not fire before the Greyline idle time (or blank is off / unreadable)")
except Exception as exc:
    print("config", exc)
PY
fi

section "systemd --user"
systemctl --user --no-pager --full status greyline-hub.service 2>&1 | head -n 20 || true
echo
systemctl --user --no-pager --full status greyline-hub-idle.service 2>&1 | head -n 20 || true

section "what to send"
echo "Paste this whole output if the dashboard does not appear after the idle time."
