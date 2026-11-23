"""Fullscreen dashboard window.

Ubuntu 26.04 GNOME/Wayland uses GTK 4 and WebKitGTK 6. If that typelib is
missing, GTK 3 / WebKit2 4.1 is next, then Chromium or Firefox in kiosk mode.
The idle service kills this process when the session sees input. Keys and
clicks also close it.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys

from greyline_hub.linux_saver import browser_command, browser_executable, choose_renderer, session_type

log = logging.getLogger("greyline.kiosk")


def available_renderers() -> set[str]:
    found = set()
    if _webkit6_present() or _webkit2_present():
        found.add("webkit")
    if browser_executable("chromium", _which):
        found.add("chromium")
    if browser_executable("firefox", _which):
        found.add("firefox")
    return found


def _which(name: str) -> str | None:
    from shutil import which

    return which(name)


def _webkit6_present() -> bool:
    try:
        import gi

        gi.require_version("Gtk", "4.0")
        gi.require_version("WebKit", "6.0")
        from gi.repository import WebKit  # noqa: F401
    except Exception:
        return False
    return True


def _webkit2_present() -> bool:
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        for version in ("4.1", "4.0"):
            try:
                gi.require_version("WebKit2", version)
            except ValueError:
                continue
            from gi.repository import WebKit2  # noqa: F401
            return True
    except Exception:
        return False
    return False


def run_webkit6(url: str, exit_on_input: bool) -> int:
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("WebKit", "6.0")
    from gi.repository import Gdk, Gio, Gtk, WebKit

    class Kiosk(Gtk.Application):
        def do_activate(self):
            window = Gtk.ApplicationWindow(application=self, title="Greyline Hub")
            window.set_decorated(False)
            view = WebKit.WebView()
            view.load_uri(url)
            window.set_child(view)
            if exit_on_input:
                keys = Gtk.EventControllerKey()
                keys.connect("key-pressed", self._quit)
                window.add_controller(keys)
                click = Gtk.GestureClick()
                click.connect("pressed", self._quit)
                window.add_controller(click)
            try:
                window.set_cursor(Gdk.Cursor.new_from_name("none", None))
            except Exception:
                pass
            window.fullscreen()
            window.present()

        def _quit(self, *_args):
            self.quit()
            return True

    app = Kiosk(application_id="com.greylinehub.kiosk", flags=Gio.ApplicationFlags.NON_UNIQUE)
    return int(app.run(None) or 0)


def run_webkit2(url: str, exit_on_input: bool) -> int:
    import gi

    gi.require_version("Gtk", "3.0")
    webkit = None
    for version in ("4.1", "4.0"):
        try:
            gi.require_version("WebKit2", version)
            webkit = version
            break
        except ValueError:
            continue
    if webkit is None:
        raise RuntimeError("WebKit2 typelib is not installed")
    from gi.repository import Gtk, WebKit2

    window = Gtk.Window(title="Greyline Hub")
    window.fullscreen()
    view = WebKit2.WebView()
    view.load_uri(url)
    window.add(view)
    if exit_on_input:
        window.connect("key-press-event", lambda *_args: Gtk.main_quit() or True)
        window.connect("button-press-event", lambda *_args: Gtk.main_quit() or True)
    window.show_all()
    Gtk.main()
    return 0


def exec_browser(kind: str, url: str, session: str) -> int:
    executable = browser_executable(kind, _which)
    if not executable:
        log.error("no %s executable on PATH", kind)
        return 1
    command = browser_command(kind, executable, url, session)
    log.info("exec %s", " ".join(command))
    os.execvp(command[0], command)
    return 1


def run_kiosk(url: str, preference: str, exit_on_input: bool) -> int:
    session = session_type()
    chosen = choose_renderer(preference, available_renderers())
    if not chosen:
        log.error("no dashboard renderer. Install gir1.2-webkit-6.0 or chromium or firefox.")
        return 1
    if preference not in {"", "auto"} and chosen != preference:
        log.warning("renderer %s is not installed; using %s", preference, chosen)
    log.info("kiosk %s via %s session=%s", url, chosen, session)
    if chosen == "webkit":
        if _webkit6_present():
            return run_webkit6(url, exit_on_input)
        return run_webkit2(url, exit_on_input)
    return exec_browser(chosen, url, session)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    parser = argparse.ArgumentParser(prog="greyline-hub kiosk")
    parser.add_argument("--url", default="http://127.0.0.1:8754/")
    parser.add_argument("--renderer", default="auto")
    parser.add_argument("--display", default="")
    parser.add_argument("--exit-on-input", action="store_true")
    args = parser.parse_args(argv)
    if args.display:
        _apply_display(args.display)
    return run_kiosk(args.url, args.renderer, args.exit_on_input)


def _apply_display(name: str) -> None:
    from greyline_hub.linux_saver import display_env

    updated = display_env(dict(os.environ), name)
    os.environ.update(updated)
