"""Linux idle detection and kiosk selection.

GNOME on Wayland (Ubuntu 26.04 and later) is the path this is written for:
Mutter's IdleMonitor on the session bus, then a GTK 4 / WebKitGTK 6 window.
X11 is the fallback (xprintidle, then Mutter if GNOME is still there, then a
browser kiosk or WebKit).
"""

from __future__ import annotations

import os
import re

RENDERERS = ("auto", "webkit", "chromium", "firefox")
CHROMIUM_NAMES = ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable")
FIREFOX_NAMES = ("firefox", "firefox-esr")


def session_type(env: dict | None = None) -> str:
    env = os.environ if env is None else env
    kind = str(env.get("XDG_SESSION_TYPE") or "").strip().lower()
    if kind in {"wayland", "x11", "tty"}:
        return kind
    if env.get("WAYLAND_DISPLAY"):
        return "wayland"
    if env.get("DISPLAY"):
        return "x11"
    return "unknown"


def parse_idle_milliseconds(text: str | None) -> int | None:
    """Accept Mutter's `(uint32 12345,)`, a bare xprintidle number, or empty."""
    if text is None:
        return None
    stripped = text.strip()
    if not stripped:
        return None
    if re.fullmatch(r"\d+", stripped):
        return int(stripped)
    numbers = re.findall(r"\d+", stripped)
    if not numbers:
        return None
    # Mutter prints "(uint32 15000,)" — the type name contains digits.
    return int(numbers[-1])


def parse_gsettings_uint(text: str | None) -> int | None:
    """`uint32 300` from gsettings, or a bare number."""
    return parse_idle_milliseconds(text)


def idle_plan(session: str, tools: set[str]) -> list[str]:
    """Backends to try, first one that answers wins.

    Wayland GNOME uses Mutter. X11 prefers xprintidle and still tries Mutter,
    because a GNOME-on-Xorg session has the same IdleMonitor.
    """
    plan: list[str] = []
    if session != "x11" and "gdbus" in tools:
        plan.append("mutter")
    if session == "x11":
        if "xprintidle" in tools:
            plan.append("xprintidle")
        if "gdbus" in tools:
            plan.append("mutter")
    if "mutter" not in plan and "gdbus" in tools:
        plan.append("mutter")
    if "xprintidle" in tools and "xprintidle" not in plan:
        plan.append("xprintidle")
    return plan


def idle_action(idle_ms: int | None, threshold_ms: int, showing: bool, activity_ms: int = 1500) -> str:
    """Return start, stop, keep, or wait.

    Once the dashboard is up it stays up until input resets the idle timer.
    A still-idle user does not dismiss it.
    """
    if idle_ms is None:
        return "keep" if showing else "wait"
    if showing:
        return "stop" if idle_ms < activity_ms else "keep"
    if idle_ms >= threshold_ms:
        return "start"
    return "wait"


def blank_conflict(gnome_idle_seconds: int | None, idle_minutes: int) -> str | None:
    """GNOME's own blank covers our window when it fires first or together."""
    if gnome_idle_seconds is None or gnome_idle_seconds == 0:
        return None
    ours = int(idle_minutes) * 60
    if gnome_idle_seconds <= ours:
        return (
            f"GNOME blanks the screen after {gnome_idle_seconds}s, which is not longer than "
            f"Greyline's {ours}s. In Settings → Power, set Blank Screen longer than "
            f"{idle_minutes} minutes, or turn it off "
            "(gsettings set org.gnome.desktop.session idle-delay 0)."
        )
    return None


def dashboard_url(cfg: dict) -> str:
    linux = cfg.get("linux") or {}
    port = int(cfg["server"]["port"] or 8754)
    if port < 1:
        port = 8754
    page = str(linux.get("page") or "/")
    if not page.startswith("/"):
        page = "/" + page
    if page != "/" and not page.endswith("/"):
        page += "/"
    return f"http://127.0.0.1:{port}{page}"


def choose_renderer(preference: str, available: set[str]) -> str:
    """auto on this Ubuntu release prefers WebKitGTK 6, then a browser."""
    prefer = (preference or "auto").lower()
    if prefer in {"webkit", "chromium", "firefox"} and prefer in available:
        return prefer
    for name in ("webkit", "chromium", "firefox"):
        if name in available:
            return name
    return ""


def browser_executable(kind: str, which) -> str | None:
    names = CHROMIUM_NAMES if kind == "chromium" else FIREFOX_NAMES
    for name in names:
        found = which(name)
        if found:
            return found
    return None


def browser_command(kind: str, executable: str, url: str, session: str) -> list[str]:
    if kind == "firefox":
        return [executable, "--kiosk", url]
    command = [
        executable,
        "--kiosk",
        "--no-first-run",
        "--disable-infobars",
        "--disable-session-crashed-bubble",
        "--disable-features=Translate",
        url,
    ]
    if session == "wayland":
        command.insert(1, "--ozone-platform=wayland")
    return command


def display_env(base: dict, display: str) -> dict:
    env = dict(base)
    text = (display or "").strip()
    if not text:
        return env
    if text.startswith("wayland"):
        env["WAYLAND_DISPLAY"] = text
    else:
        env["DISPLAY"] = text if text.startswith(":") else text
    return env


def insert_xscreensaver_program(text: str, command: str) -> tuple[str, bool]:
    """Add one programs: entry. Return the text and whether it changed."""
    if "greyline-hub" in text:
        return text, False
    marker = "programs:"
    index = text.find(marker)
    if index < 0:
        return text, False
    newline = text.find("\n", index)
    if newline < 0:
        return text, False
    line = f"\n\t\t\t\tgreyline-hub-xscreensaver --root \\n\\"
    if command and command != "greyline-hub-xscreensaver --root":
        line = f"\n\t\t\t\t{command} \\n\\"
    return text[:newline] + line + text[newline:], True

