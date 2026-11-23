"""Launcher for the Linux session.

Ubuntu's AppIndicator extension gets a status icon when the Ayatana typelib
is installed. Otherwise this opens a small GTK 4 window with the same actions.
Autostart stays quiet when there is no indicator, so login does not pop a window.
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import webbrowser

from greyline_hub.config import ConfigError, discover_config
from greyline_hub.linux_saver import dashboard_url

log = logging.getLogger("greyline.tray")
SERVER = "greyline-hub.service"
IDLE = "greyline-hub-idle.service"


def config_url() -> str:
    try:
        cfg, _path, _example = discover_config(None)
    except ConfigError:
        return "http://127.0.0.1:8754/config/"
    base = dashboard_url(cfg)
    root = base.split("://", 1)[-1]
    host = root.split("/", 1)[0]
    return f"http://{host}/config/"


def systemctl(*args: str) -> str:
    try:
        completed = subprocess.run(
            ["systemctl", "--user", *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return str(exc)
    text = (completed.stdout or completed.stderr or "").strip()
    return text or f"exit {completed.returncode}"


def status_line() -> str:
    server = systemctl("is-active", SERVER).strip()
    idle = systemctl("is-active", IDLE).strip()
    return f"Server {server}    Saver {idle}"


def open_config(*_args) -> None:
    webbrowser.open(config_url())


def test_saver(*_args) -> None:
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    subprocess.Popen(
        [sys.executable, os.path.join(repo, "greyline-hub"), "kiosk", "--exit-on-input"],
        cwd=repo,
        start_new_session=True,
    )


def _indicator_available() -> bool:
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3  # noqa: F401
    except Exception:
        return False
    return True


def run_indicator() -> int:
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
    from gi.repository import Gtk

    indicator = AppIndicator.Indicator.new(
        "greyline-hub",
        "video-display",
        AppIndicator.IndicatorCategory.APPLICATION_STATUS,
    )
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
    indicator.set_title("Greyline Hub")
    menu = Gtk.Menu()

    def add(label, callback):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", lambda *_a: callback())
        menu.append(item)

    state = Gtk.MenuItem(label=status_line())
    state.set_sensitive(False)
    menu.append(state)
    add("Open configuration", open_config)
    add("Test saver now", test_saver)
    add("Start services", lambda: (systemctl("start", SERVER), systemctl("start", IDLE), state.set_label(status_line())))
    add("Stop services", lambda: (systemctl("stop", IDLE), systemctl("stop", SERVER), state.set_label(status_line())))
    add("Restart services", lambda: (systemctl("restart", SERVER), systemctl("restart", IDLE), state.set_label(status_line())))
    add("Quit", Gtk.main_quit)
    menu.show_all()
    indicator.set_menu(menu)
    Gtk.main()
    return 0


def run_window() -> int:
    import gi

    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk

    class Controls(Gtk.Application):
        def do_activate(self):
            window = Gtk.ApplicationWindow(application=self, title="Greyline Hub")
            window.set_default_size(360, 280)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            box.set_margin_top(16)
            box.set_margin_bottom(16)
            box.set_margin_start(16)
            box.set_margin_end(16)
            self.label = Gtk.Label(label=status_line())
            self.label.set_wrap(True)
            box.append(self.label)
            for title, callback in (
                ("Open configuration", open_config),
                ("Test saver now", test_saver),
                ("Start services", lambda: (systemctl("start", SERVER), systemctl("start", IDLE), self._refresh())),
                ("Stop services", lambda: (systemctl("stop", IDLE), systemctl("stop", SERVER), self._refresh())),
                ("Restart services", lambda: (systemctl("restart", SERVER), systemctl("restart", IDLE), self._refresh())),
                ("Refresh status", self._refresh),
            ):
                button = Gtk.Button(label=title)
                button.connect("clicked", lambda _b, fn=callback: fn())
                box.append(button)
            window.set_child(box)
            window.present()

        def _refresh(self, *_args):
            self.label.set_label(status_line())

    app = Controls(application_id="com.greylinehub.tray")
    return int(app.run(None) or 0)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    argv = list(sys.argv[1:] if argv is None else argv)
    autostart = "--autostart" in argv or os.environ.get("GREYLINE_TRAY_AUTOSTART") == "1"
    if _indicator_available():
        return run_indicator()
    if autostart:
        log.info("no AppIndicator typelib; not opening a window at login")
        return 0
    try:
        return run_window()
    except Exception as exc:
        log.error("GTK window failed: %s", exc)
        print(status_line())
        print("Open", config_url())
        return 1
