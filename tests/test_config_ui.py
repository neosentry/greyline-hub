import json
import tempfile
import threading
import unittest
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from greyline_hub.cache import FeedCache
from greyline_hub.config import ConfigError, prepare
from greyline_hub.config_api import apply_form, client_is_local
from greyline_hub.hub import Service
from greyline_hub.layout import layout_document
from greyline_hub.server import HubServer
from greyline_hub.status import build_status


class LayoutTests(unittest.TestCase):
    def test_custom_pages_stay_when_layout_is_absent(self):
        cfg = prepare(
            {
                "server": {"enabled": True, "port": 8754},
                "publish": {"enabled": False, "directory": ""},
                "pages": [{"id": "main", "title": "Shack", "slug": "", "panels": ["map", "clock"]}],
            }
        )
        self.assertEqual(cfg["pages"][0]["panels"], ["clock", "map"])

    def test_map_heavy_preset_sets_panels_and_regions(self):
        cfg = prepare({"layout": {"preset": "map-heavy"}})
        page = cfg["pages"][0]
        self.assertEqual(page["panels"], ["clock", "map", "dx_spots"])
        self.assertEqual(page["dx_rows"], 4)
        document = layout_document(cfg)
        self.assertEqual(document["schema"], 1)
        self.assertEqual(document["preset"], "map-heavy")
        self.assertTrue(document["regions"])
        self.assertTrue(all("row" in region and "cols" in region for region in document["regions"]))

    def test_bad_grid_is_rejected(self):
        with self.assertRaises(ConfigError):
            apply_form({}, {"station": {"callsign": "K0JNM", "grid": "99", "timezone": "UTC"}})

    def test_form_round_trip_writes_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text("{}\n", encoding="utf-8")
            updated = apply_form(
                {},
                {
                    "station": {"callsign": "k0jnm", "grid": "EL87uu", "timezone": "America/New_York"},
                    "server": {"port": 8754, "enabled": True},
                    "publish": [{"directory": str(Path(tmp) / "greyline"), "enabled": True}],
                    "layout": {"preset": "spots-heavy", "dx_rows": 18},
                    "dx_filter": {"bands": ["20m"], "modes": ["FT8"], "max_count": 18},
                    "lan_writes": False,
                },
            )
            self.assertEqual(updated["station"]["callsign"], "K0JNM")
            self.assertEqual(updated["station"]["grid"], "EL87uu")
            self.assertAlmostEqual(updated["station"]["latitude"], 27.854167, places=4)
            cfg = prepare(updated)
            self.assertIn("dx_spots", cfg["pages"][0]["panels"])
            self.assertNotIn("bands", cfg["pages"][0]["panels"])
            self.assertEqual(cfg["dx_filter"]["bands"], ["20m"])
            self.assertTrue(cfg["publish"]["enabled"])

    def test_spot_filter_and_layout_file(self):
        cfg = prepare(
            {
                "layout": {"preset": "shack", "dx_rows": 10},
                "dx_filter": {"bands": ["20m"], "modes": [], "max_count": 5},
            }
        )
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        spots = [
            {"dx": "A", "freq_khz": 14074, "band": "20m", "mode": "FT8", "time": now},
            {"dx": "B", "freq_khz": 7074, "band": "40m", "mode": "FT8", "time": now},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            cache = FeedCache(Path(tmp) / "cache.json")
            cache.put("dx_http", spots)
            status = build_status(cfg, cache, None, datetime.now(timezone.utc))
            self.assertEqual([item["dx"] for item in status["spots"]["items"]], ["A"])
            site_root = Path(tmp) / "site"
            from greyline_hub.site import Site

            site = Site(site_root)
            site.write_status(status, layout_document(cfg))
            saved = json.loads((site_root / "data" / "layout.json").read_text())
            self.assertEqual(saved["dx_filter"]["bands"], ["20m"])
            self.assertEqual(saved["station"]["callsign"], "K0JNM")


class ConfigHttpTests(unittest.TestCase):
    def test_localhost_only_and_post(self):
        self.assertTrue(client_is_local(("127.0.0.1", 9)))
        self.assertTrue(client_is_local(("::ffff:127.0.0.1", 9)))
        self.assertFalse(client_is_local(("192.168.1.20", 9)))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_path = root / "config.json"
            config_path.write_text(
                json.dumps({"server": {"enabled": True, "host": "127.0.0.1", "port": 8754}, "publish": {"enabled": False}}),
                encoding="utf-8",
            )
            cfg = prepare(json.loads(config_path.read_text()))
            cfg["runtime_dir"] = str(root / "rt")
            service = Service(cfg, config_path)
            service.site.rebuild(cfg, force=True)
            from greyline_hub.config_api import ConfigHooks

            server = HubServer("127.0.0.1", 0, "", service.site.directory, ConfigHooks(service))
            service.server = server
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.port}"
            try:
                with urllib.request.urlopen(base + "/config/", timeout=3) as response:
                    page = response.read().decode()
                    self.assertIn("GREYLINE", page)
                with urllib.request.urlopen(base + "/api/config", timeout=3) as response:
                    payload = json.loads(response.read())
                    self.assertTrue(payload["ok"])
                    self.assertEqual(payload["config"]["station"]["callsign"], "K0JNM")
                body = json.dumps(
                    {
                        "station": {"callsign": "K0JNM", "grid": "EL87uu", "timezone": "America/New_York"},
                        "server": {"port": 8754, "enabled": True},
                        "publish": [],
                        "layout": {"preset": "map-heavy", "panels": [], "dx_rows": 4},
                        "dx_filter": {"bands": [], "modes": ["CW"], "max_count": 4},
                        "lan_writes": False,
                    }
                ).encode()
                request = urllib.request.Request(base + "/api/config", data=body, headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=3) as response:
                    saved = json.loads(response.read())
                self.assertTrue(saved["ok"])
                self.assertEqual(saved["config"]["layout"]["preset"], "map-heavy")
                on_disk = json.loads(config_path.read_text())
                self.assertEqual(on_disk["station"]["grid"], "EL87uu")
                self.assertFalse(on_disk["config_api"]["lan_writes"])
                layout = json.loads((service.site.directory / "data" / "layout.json").read_text())
                self.assertEqual(layout["preset"], "map-heavy")
                self.assertNotIn("bands", layout["panels"])
            finally:
                server.shutdown()

    def test_short_callsign_and_relative_folder_are_rejected(self):
        with self.assertRaises(ConfigError):
            apply_form({}, {"station": {"callsign": "NO", "grid": "EL87uu", "timezone": "UTC"}})
        with self.assertRaises(ConfigError):
            apply_form(
                {},
                {
                    "station": {"callsign": "K0JNM", "grid": "EL87uu", "timezone": "UTC"},
                    "server": {"port": 8754, "enabled": True},
                    "publish": [{"directory": "relative/greyline", "enabled": True}],
                },
            )
