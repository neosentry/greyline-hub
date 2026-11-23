import unittest

from greyline_hub.config import ConfigError, prepare
from greyline_hub.linux_saver import (
    blank_conflict,
    browser_command,
    choose_renderer,
    dashboard_url,
    idle_action,
    idle_plan,
    insert_xscreensaver_program,
    parse_gsettings_uint,
    parse_idle_milliseconds,
    session_type,
)


class LinuxSaverTests(unittest.TestCase):
    def test_wayland_gnome_prefers_mutter(self):
        self.assertEqual(session_type({"XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0"}), "wayland")
        self.assertEqual(idle_plan("wayland", {"gdbus", "xprintidle"}), ["mutter", "xprintidle"])
        self.assertEqual(idle_plan("x11", {"gdbus", "xprintidle"}), ["xprintidle", "mutter"])

    def test_mutter_and_xprintidle_text(self):
        self.assertEqual(parse_idle_milliseconds("(uint32 15000,)"), 15000)
        self.assertEqual(parse_idle_milliseconds("(uint64 42,)"), 42)
        self.assertEqual(parse_idle_milliseconds("15000\n"), 15000)
        self.assertIsNone(parse_idle_milliseconds(""))
        self.assertEqual(parse_gsettings_uint("uint32 300"), 300)

    def test_hysteresis(self):
        threshold = 5 * 60_000
        self.assertEqual(idle_action(threshold, threshold, False), "start")
        self.assertEqual(idle_action(threshold + 10_000, threshold, True), "keep")
        self.assertEqual(idle_action(200, threshold, True), "stop")
        self.assertEqual(idle_action(None, threshold, True), "keep")
        self.assertEqual(idle_action(None, threshold, False), "wait")

    def test_renderer_order_and_wayland_chromium(self):
        self.assertEqual(choose_renderer("auto", {"firefox", "webkit", "chromium"}), "webkit")
        self.assertEqual(choose_renderer("auto", {"firefox"}), "firefox")
        self.assertEqual(choose_renderer("chromium", {"webkit", "chromium"}), "chromium")
        command = browser_command("chromium", "/usr/bin/chromium", "http://127.0.0.1:8754/", "wayland")
        self.assertIn("--ozone-platform=wayland", command)
        self.assertIn("--kiosk", command)
        self.assertTrue(command[-1].endswith(":8754/"))

    def test_blank_screen_must_be_later(self):
        self.assertIsNone(blank_conflict(0, 5))
        self.assertIsNone(blank_conflict(None, 5))
        self.assertIsNone(blank_conflict(900, 5))
        warning = blank_conflict(300, 5)
        self.assertIn("300s", warning)
        self.assertIn("idle-delay", warning)

    def test_linux_config_round_trip(self):
        cfg = prepare({"linux": {"idle_minutes": 8, "renderer": "webkit", "page": "map", "display": ""}})
        self.assertEqual(cfg["linux"]["idle_minutes"], 8)
        self.assertEqual(cfg["linux"]["page"], "/map")
        self.assertEqual(dashboard_url(cfg), "http://127.0.0.1:8754/map/")
        with self.assertRaises(ConfigError):
            prepare({"linux": {"idle_minutes": 0}})
        with self.assertRaises(ConfigError):
            prepare({"linux": {"renderer": "safari"}})

    def test_xscreensaver_line_is_inserted_once(self):
        original = "timeout: 0:10:00\nprograms:\n- qix -root \\n\\\n"
        updated, changed = insert_xscreensaver_program(original, "greyline-hub-xscreensaver --root")
        self.assertTrue(changed)
        self.assertIn("greyline-hub-xscreensaver --root", updated)
        again, changed_again = insert_xscreensaver_program(updated, "greyline-hub-xscreensaver --root")
        self.assertFalse(changed_again)
        self.assertEqual(again, updated)
        untouched, changed_no_programs = insert_xscreensaver_program("mode: one\n", "greyline-hub-xscreensaver --root")
        self.assertFalse(changed_no_programs)
        self.assertEqual(untouched, "mode: one\n")
