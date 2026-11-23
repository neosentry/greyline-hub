"""Watch the session idle time and show the dashboard.

Started by the greyline-hub-idle user service after the GNOME session is up.
"""

from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from greyline_hub.config import ConfigError, discover_config
from greyline_hub.linux_saver import (
    blank_conflict,
    dashboard_url,
    display_env,
    idle_action,
    idle_plan,
    parse_gsettings_uint,
    parse_idle_milliseconds,
    session_type,
)

log = logging.getLogger("greyline.idle")


def mutter_idle_ms() -> int | None:
    try:
        completed = subprocess.run(
            [
                "gdbus",
                "call",
                "--session",
                "--dest",
                "org.gnome.Mutter.IdleMonitor",
                "--object-path",
                "/org/gnome/Mutter/IdleMonitor/Core",
                "--method",
                "org.gnome.Mutter.IdleMonitor.GetIdletime",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    return parse_idle_milliseconds(completed.stdout)


def xprintidle_ms() -> int | None:
    try:
        completed = subprocess.run(
            ["xprintidle"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    return parse_idle_milliseconds(completed.stdout)


def read_idle_ms(plan: list[str]) -> int | None:
    for backend in plan:
        if backend == "mutter":
            value = mutter_idle_ms()
        elif backend == "xprintidle":
            value = xprintidle_ms()
        else:
            value = None
        if value is not None:
            return value
    return None


def gnome_blank_seconds() -> int | None:
    try:
        completed = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.session", "idle-delay"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    return parse_gsettings_uint(completed.stdout)


def tool_set() -> set[str]:
    found = set()
    for name in ("gdbus", "xprintidle"):
        if shutil_which(name):
            found.add(name)
    return found


def shutil_which(name: str) -> str | None:
    from shutil import which

    return which(name)


class KioskProcess:
    def __init__(self, popen):
        self.popen = popen

    @property
    def pid(self) -> int:
        return self.popen.pid

    def running(self) -> bool:
        return self.popen.poll() is None

    def stop(self) -> None:
        if not self.running():
            return
        try:
            os.killpg(self.popen.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            self.popen.terminate()
        try:
            self.popen.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.popen.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                self.popen.kill()


def launch_kiosk(cfg: dict, root: Path) -> KioskProcess:
    url = dashboard_url(cfg)
    linux = cfg["linux"]
    command = [
        sys.executable,
        str(root / "greyline-hub"),
        "kiosk",
        "--url",
        url,
        "--renderer",
        linux["renderer"],
        "--exit-on-input",
    ]
    if linux.get("display"):
        command.extend(["--display", linux["display"]])
    env = display_env(os.environ.copy(), linux.get("display") or "")
    log.info("showing %s with renderer %s", url, linux["renderer"])
    proc = subprocess.Popen(command, cwd=str(root), env=env, start_new_session=True)
    return KioskProcess(proc)


def run(root: Path, config: str | None = None) -> int:
    stop = False

    def _stop(*_args) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    session = session_type()
    plan = idle_plan(session, tool_set())
    log.info("session=%s idle backends=%s", session, ",".join(plan) or "none")
    if not plan:
        log.error("no idle backend. On GNOME/Wayland, gdbus must reach org.gnome.Mutter.IdleMonitor.")
        return 1
    kiosk: KioskProcess | None = None
    warned = False
    try:
        while not stop:
            try:
                cfg, _path, _example = discover_config(config)
            except ConfigError as exc:
                log.error("config: %s", exc)
                time.sleep(5)
                continue
            if not warned:
                conflict = blank_conflict(gnome_blank_seconds(), cfg["linux"]["idle_minutes"])
                if conflict:
                    log.warning("%s", conflict)
                warned = True
            idle_ms = read_idle_ms(plan)
            showing = kiosk is not None and kiosk.running()
            if kiosk is not None and not kiosk.running():
                kiosk = None
                showing = False
            action = idle_action(idle_ms, cfg["linux"]["idle_minutes"] * 60_000, showing)
            if action == "start" and kiosk is None:
                kiosk = launch_kiosk(cfg, root)
            elif action == "stop" and kiosk is not None:
                log.info("input detected, closing the dashboard")
                kiosk.stop()
                kiosk = None
            time.sleep(2)
    finally:
        if kiosk is not None:
            kiosk.stop()
    return 0


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    argv = list(sys.argv[1:] if argv is None else argv)
    config = None
    if "--config" in argv:
        index = argv.index("--config")
        config = argv[index + 1]
    root = Path(__file__).resolve().parent.parent
    return run(root, config)
