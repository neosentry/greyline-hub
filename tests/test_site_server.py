import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from greyline_hub.cache import FeedCache
from greyline_hub.config import prepare
from greyline_hub.server import HubServer
from greyline_hub.site import PublishError, Site, assert_publish_directory
from greyline_hub.status import build_status


class SiteTests(unittest.TestCase):
    def test_pages_are_relative_and_publish_is_guarded(self):
        cfg = prepare(
            {
                "server": {"enabled": True, "port": 0, "host": "127.0.0.1"},
                "publish": {"enabled": False},
                "pages": [
                    {"id": "main", "title": "Shack", "slug": "", "panels": ["map", "clock"]},
                    {"id": "night", "title": "Night", "slug": "night", "panels": ["map"]},
                ],
            }
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            site = Site(tmp_path / "site")
            site.rebuild(cfg, force=True)
            root_html = (tmp_path / "site" / "index.html").read_text()
            nested = (tmp_path / "site" / "night" / "index.html").read_text()
            self.assertIn('content="main"', root_html)
            self.assertIn('href="assets/app.css"', root_html)
            self.assertIn('content="../data/status.json"', nested)
            self.assertIn('src="../assets/app.js"', nested)
            self.assertIn("Night", (tmp_path / "site" / "pages" / "index.html").read_text())

            foreign = tmp_path / "www"
            foreign.mkdir()
            (foreign / "index.html").write_text("<html><title>Other site</title></html>")
            with self.assertRaises(PublishError):
                assert_publish_directory(foreign)

            publish = tmp_path / "greyline"
            published = Site(tmp_path / "runtime", publish)
            published.rebuild(cfg, force=True)
            self.assertTrue((publish / "night" / "index.html").is_file())
            self.assertTrue((publish / "assets" / "land.geojson").is_file())
            published.write_status({"server_time": "2026-11-22T00:00:00Z"})
            saved = json.loads((publish / "data" / "status.json").read_text())
            self.assertEqual(saved["server_time"], "2026-11-22T00:00:00Z")
            self.assertTrue(json.loads((publish / "health.json").read_text())["ok"])

            # A removed page folder that we created is deleted. A stranger's folder is not.
            cfg["pages"] = [page for page in cfg["pages"] if page["slug"] != "night"]
            (publish / "notes").mkdir()
            (publish / "notes" / "index.html").write_text("keep me")
            published.rebuild(cfg, force=True)
            self.assertFalse((publish / "night").exists())
            self.assertTrue((publish / "notes" / "index.html").is_file())

            blocked = tmp_path / "not-a-directory"
            blocked.write_text("x")
            guarded = Site(tmp_path / "runtime-2", blocked / "site")
            guarded.rebuild(cfg, force=True)
            self.assertTrue((tmp_path / "runtime-2" / "index.html").is_file())

    def test_custom_port_base_path_and_stale_status(self):
        cfg = prepare(
            {
                "server": {"enabled": True, "host": "127.0.0.1", "port": 0, "base_path": "/radio"},
                "publish": {"enabled": False},
                "pages": [{"id": "main", "title": "Shack", "slug": "", "panels": ["clock", "map"]}],
            }
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            site = Site(tmp_path / "site")
            site.rebuild(cfg, force=True)
            cache = FeedCache(tmp_path / "cache.json")
            cache.put("sw_sfi", {"value": 100, "at": "2020-01-01T00:00:00Z", "source": "test"})
            cache.fail("sw_sfi", "timed out")
            status = build_status(cfg, cache, None)
            self.assertTrue(status["space_weather"]["stale"])
            self.assertEqual(status["space_weather"]["sfi"]["value"], 100)
            self.assertIsNotNone(status["solar"]["declination"])
            self.assertIn("grid", status["solar"])
            site.write_status(status)

            server = HubServer("127.0.0.1", 0, "/radio", site.directory)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.port}/radio"
                with urllib.request.urlopen(base + "/api/health", timeout=3) as response:
                    self.assertEqual(response.status, 200)
                    self.assertTrue(json.loads(response.read())["ok"])
                with urllib.request.urlopen(base + "/", timeout=3) as response:
                    body = response.read().decode()
                self.assertIn("greyline-page", body)
                with urllib.request.urlopen(base + "/api/status", timeout=3) as response:
                    payload = json.loads(response.read())
                self.assertEqual(payload["space_weather"]["sfi"]["value"], 100)
                missing = urllib.request.Request(base + "/nope")
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(missing, timeout=3)
                self.assertEqual(caught.exception.code, 404)
            finally:
                server.shutdown()


if __name__ == "__main__":
    unittest.main()
