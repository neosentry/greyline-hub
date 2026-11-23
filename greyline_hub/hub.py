"""Run the feed loop, the optional HTTP server, and folder publishing."""

from __future__ import annotations

import logging
import signal
import socket
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

from greyline_hub.cache import FeedCache
from greyline_hub.config import ConfigError, load_config
from greyline_hub.cty import load_cty
from greyline_hub.feeds import TelnetSpots, collect_bands, collect_dx, collect_space_weather
from greyline_hub.paths import CTY_PATH, ROOT
from greyline_hub.server import HubServer
from greyline_hub.site import PublishError, Site
from greyline_hub.status import build_status

log = logging.getLogger("greyline")


def lan_ip() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("10.255.255.255", 1))
            return sock.getsockname()[0]
    except OSError:
        return None


def screensaver_publish_dirs() -> list[Path]:
    """Folders the macOS screen saver can read without using the network.

    legacyScreenSaver's sandbox blocks outgoing connections, including
    127.0.0.1. It can read its own container, so the unsandboxed server
    writes a copy of the site there.
    """
    if sys.platform != "darwin":
        return []
    home = Path.home()
    names = (
        "com.apple.ScreenSaver.Engine.legacyScreenSaver",
        "com.apple.ScreenSaver.Engine.legacyScreenSaver-arm64",
        "com.apple.ScreenSaver.Engine.legacyScreenSaver-x86_64",
    )
    folders = [
        home / "Library/Containers" / name / "Data/Library/Application Support/GreylineHub/site"
        for name in names
    ]
    folders.append(home / "Library/Application Support/GreylineHub/site")
    return folders


def runtime_dir(cfg: dict) -> Path:
    configured = str(cfg.get("runtime_dir") or "").strip()
    path = Path(configured).expanduser() if configured else ROOT / "var"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _log_urls(cfg: dict, port: int | None) -> None:
    if cfg["server"]["enabled"] and port is not None:
        host = cfg["server"]["host"]
        shown = host if host not in {"0.0.0.0", "::"} else (lan_ip() or "127.0.0.1")
        base = cfg["server"]["base_path"]
        log.info("built-in server http://%s:%s%s/", shown, port, base)
        for page in cfg["pages"]:
            path = base + ("/" if not page["slug"] else f"/{page['slug']}/")
            log.info("  page %-12s http://%s:%s%s", page["title"], shown, port, path)
        log.info("  page index      http://%s:%s%s/pages/", shown, port, base)
    if cfg["publish"]["enabled"]:
        folder = cfg["publish"]["directory"]
        log.info("publishing files into %s", folder)
        for page in cfg["pages"]:
            suffix = "" if not page["slug"] else page["slug"] + "/"
            log.info("  page %-12s %s/%s", page["title"], folder.rstrip("/"), suffix)


def _summary(status: dict) -> str:
    sw = status["space_weather"]
    return (
        f"SFI {sw['sfi']['value']}  SSN {sw['ssn']['value']}  "
        f"Kp {sw['kp']['value']}  A {sw['a']['value']}  "
        f"X-ray {sw['xray']['value']}  spots {status['spots']['count']}"
    )


class Service:
    def __init__(self, cfg: dict, config_path: Path):
        self.cfg = cfg
        self.config_path = config_path
        self.stop = threading.Event()
        self.cache = FeedCache(runtime_dir(cfg) / "cache.json")
        self.countries = load_cty(CTY_PATH)
        publish = None
        if cfg["publish"]["enabled"]:
            publish = Path(cfg["publish"]["directory"]).expanduser()
        extras = screensaver_publish_dirs()
        self.site = Site(runtime_dir(cfg) / "site", publish, extras)
        for folder in self.site.publish_directories:
            if publish is None or folder != publish:
                log.info("also publishing for the screen saver into %s", folder)
        self.server: HubServer | None = None
        self._telnet: TelnetSpots | None = None

    def start_telnet(self, cfg: dict) -> None:
        feeds = cfg["feeds"]
        if not feeds.get("telnet_enabled"):
            return
        if self._telnet:
            return
        login = (feeds.get("telnet_login") or "").strip() or cfg["station_resolved"]["callsign"]
        self._telnet = TelnetSpots(
            feeds["telnet_host"],
            int(feeds["telnet_port"]),
            login,
            float(feeds["dx_max_age_min"]),
        )
        self._telnet.start()

    def reload(self) -> None:
        if not self.config_path.is_file():
            return
        try:
            cfg, _, _ = load_config(self.config_path)
        except (ConfigError, OSError) as exc:
            log.error("config reload failed: %s", exc)
            return
        previous = self.cfg
        bind_changed = (
            cfg["server"]["host"] != previous["server"]["host"]
            or cfg["server"]["port"] != previous["server"]["port"]
            or cfg["server"]["base_path"] != previous["server"]["base_path"]
            or cfg["server"]["enabled"] != previous["server"]["enabled"]
        )
        if bind_changed:
            log.warning("server host, port, or base path changed; restart Greyline Hub to apply it")
        publish_changed = cfg["publish"] != previous["publish"]
        if publish_changed:
            log.warning("publish settings changed; restart Greyline Hub to apply them")
        self.cfg = cfg
        try:
            self.site.rebuild(cfg)
        except PublishError as exc:
            log.error("%s", exc)
        self.start_telnet(cfg)
        log.info("reloaded %s", self.config_path)

    def refresh_feeds(self, which: set[str]) -> None:
        cfg = self.cfg
        timeout = float(cfg["feeds"]["timeout_sec"])
        if "space" in which:
            collect_space_weather(self.cache, timeout)
        if "bands" in which:
            collect_bands(self.cache, timeout)
        if "dx" in which:
            collect_dx(
                self.cache,
                timeout,
                cfg["feeds"]["dx_url"],
                cfg["feeds"]["dx_longitude"],
            )
            self._capture_telnet()
        self.cache.save()

    def _capture_telnet(self) -> None:
        if not self._telnet:
            return
        spots = self._telnet.snapshot()
        if spots or self._telnet.connected:
            self.cache.put("dx_telnet", spots)
        elif self._telnet.last_error:
            self.cache.fail("dx_telnet", self._telnet.last_error)

    def write_status(self) -> dict:
        status = build_status(self.cfg, self.cache, self.countries, datetime.now(timezone.utc))
        try:
            self.site.write_status(status)
        except PublishError as exc:
            log.error("%s", exc)
        return status

    def loop(self) -> None:
        cfg = self.cfg
        next_space = 0.0
        next_bands = 0.0
        next_dx = 0.0
        next_status = 0.0
        mtime = self.config_path.stat().st_mtime if self.config_path.is_file() else 0.0
        self.start_telnet(cfg)
        while not self.stop.is_set():
            if self.config_path.is_file():
                current = self.config_path.stat().st_mtime
                if current != mtime:
                    mtime = current
                    self.reload()
            now = time_now()
            which: set[str] = set()
            feeds = self.cfg["feeds"]
            if now >= next_space:
                which.add("space")
                next_space = now + feeds["space_weather_sec"]
            if now >= next_bands:
                which.add("bands")
                next_bands = now + feeds["bands_sec"]
            if now >= next_dx:
                which.add("dx")
                next_dx = now + feeds["dx_sec"]
            if which:
                self.refresh_feeds(which)
                status = self.write_status()
                log.info("%s", _summary(status))
                next_status = time_now() + self.cfg["publish"]["status_interval_sec"]
            elif now >= next_status:
                self._capture_telnet()
                self.write_status()
                next_status = now + self.cfg["publish"]["status_interval_sec"]
            self.stop.wait(1.0)

    def run(self) -> None:
        cfg = self.cfg
        try:
            self.site.rebuild(cfg, force=True)
        except PublishError as exc:
            raise SystemExit(str(exc)) from exc
        self.write_status()
        if cfg["server"]["enabled"]:
            self.server = HubServer(
                cfg["server"]["host"],
                int(cfg["server"]["port"]),
                cfg["server"]["base_path"],
                self.site.directory,
            )
        _log_urls(cfg, self.server.port if self.server else None)
        if not cfg["server"]["enabled"]:
            log.info("folder mode: not listening on a port")

        def _stop(*_args) -> None:
            self.stop.set()

        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)
        worker = threading.Thread(target=self.loop, name="greyline-feeds", daemon=True)
        worker.start()
        if self.server:
            thread = threading.Thread(target=self.server.serve_forever, name="greyline-http", daemon=True)
            thread.start()
        while not self.stop.is_set():
            self.stop.wait(0.5)
        if self._telnet:
            self._telnet.stop()
        if self.server:
            self.server.shutdown()


def time_now() -> float:
    import time

    return time.time()


def run_check(cfg: dict) -> int:
    service = Service(cfg, Path("/dev/null"))
    service.refresh_feeds({"space", "bands", "dx"})
    status = service.write_status()
    print(_summary(status))
    sw = status["space_weather"]
    for label, block in (
        ("SFI", sw["sfi"]),
        ("SSN", sw["ssn"]),
        ("Kp", sw["kp"]),
        ("A", sw["a"]),
        ("X-ray", sw["xray"]),
        ("Wind", sw["solar_wind"]),
        ("Bz", sw["bz"]),
    ):
        print(f"  {label:6} {block['value']}  {block['source'] or ''}")
    scales = sw["scales"]
    print(f"  scales R{scales['R']} S{scales['S']} G{scales['G']}  {sw.get('geomag') or ''}")
    bands = status["bands"]
    print(f"  bands  {bands['source'] or 'none'}  estimated={bands['estimated']}")
    print(f"  spots  {status['spots']['count']} from {status['spots']['source']}")
    for key, feed in status["feeds"].items():
        if feed.get("error"):
            print(f"  note   {key}: {feed['error']}")
    if sw["empty"] and status["spots"]["empty"]:
        return 1
    return 0
