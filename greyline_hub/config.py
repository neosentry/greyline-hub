"""JSON configuration, with // and /* */ comments allowed.

Pages are the thing screensaver clients open. Each page has a stable path and
a set of panels. The built-in server publishes those paths on ``server.port``.
Folder mode writes the same paths into ``publish.directory`` so an existing
web server can serve them without giving Greyline Hub a port.
"""

from __future__ import annotations

import copy
import json
import os
import re
from pathlib import Path

from greyline_hub.maidenhead import GridError, format_grid, grid_to_latlon, latlon_to_grid
from greyline_hub.paths import ROOT

PANEL_IDS = ("clock", "map", "space_weather", "bands", "dx_spots")
_SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")


class ConfigError(ValueError):
    pass


def _page(page_id: str, title: str, slug: str, panels: list[str], **extra) -> dict:
    base = {
        "id": page_id,
        "title": title,
        "slug": slug,
        "panels": panels,
        "dx_rows": 10,
        "show_vhf": True,
        "map": {
            "spots": True,
            "labels": True,
            "greyline": True,
            "home": True,
            "sun": True,
            "graticule": True,
        },
        "burn_in": {"enabled": True, "period_sec": 180, "pixels": 8},
    }
    base.update(extra)
    return base


DEFAULTS: dict = {
    "station": {
        "callsign": "K0JNM",
        "grid": "EL87uu",
        "latitude": None,
        "longitude": None,
        "timezone": "America/New_York",
    },
    "server": {
        "enabled": True,
        "host": "0.0.0.0",
        "port": 8754,
        "base_path": "",
    },
    "publish": {
        "enabled": False,
        "directory": "",
        "status_interval_sec": 15,
    },
    "pages": [
        _page(
            "main",
            "Shack",
            "",
            ["clock", "map", "space_weather", "bands", "dx_spots"],
        ),
        _page(
            "map",
            "Map",
            "map",
            ["clock", "map", "dx_spots"],
            dx_rows=8,
            show_vhf=False,
        ),
    ],
    "clients": [],
    "feeds": {
        "timeout_sec": 12,
        "space_weather_sec": 300,
        "bands_sec": 600,
        "dx_sec": 60,
        "dx_url": "https://www.dxsummit.fi/api/v1/spots?limit=40",
        "dx_longitude": "west-positive",
        "dx_max_age_min": 90,
        "dx_max_spots": 60,
        "telnet_enabled": False,
        "telnet_host": "dxc.nc7j.com",
        "telnet_port": 7373,
        "telnet_login": "",
    },
    "runtime_dir": "",
    "dx_filter": {
        "bands": [],
        "modes": [],
        "max_count": 60,
    },
    "config_api": {
        "lan_writes": False,
    },
}


def strip_json_comments(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    escaped = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i = min(n, i + 2)
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def deep_merge(base: dict, override: dict) -> dict:
    """Merge objects. Lists and scalars in the override replace the base."""
    merged = copy.deepcopy(base)
    for key, value in override.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def normalize_base_path(value: str | None) -> str:
    text = (value or "").strip()
    if not text or text == "/":
        return ""
    if not text.startswith("/"):
        text = "/" + text
    return text.rstrip("/")


def normalize_pages(pages: list) -> list[dict]:
    if not isinstance(pages, list) or not pages:
        raise ConfigError("pages must be a non-empty list")
    normalized = []
    seen_slugs: set[str] = set()
    seen_ids: set[str] = set()
    for raw in pages:
        if not isinstance(raw, dict):
            raise ConfigError("each page must be an object")
        page_id = str(raw.get("id") or f"page{len(normalized) + 1}").strip()
        if not page_id or page_id in seen_ids:
            raise ConfigError(f"duplicate or empty page id {page_id!r}")
        seen_ids.add(page_id)
        slug = str(raw.get("slug") if raw.get("slug") is not None else page_id).strip().strip("/")
        if slug and not _SLUG.fullmatch(slug):
            raise ConfigError(
                f"page {page_id!r} slug {slug!r} must be letters, numbers, hyphen, or underscore"
            )
        if slug in seen_slugs:
            raise ConfigError(f"two pages use the path {slug or '/'!r}")
        seen_slugs.add(slug)
        panels = raw.get("panels", list(PANEL_IDS))
        if not isinstance(panels, list):
            raise ConfigError(f"page {page_id!r} panels must be a list")
        unknown = [item for item in panels if item not in PANEL_IDS]
        if unknown:
            raise ConfigError(
                f"page {page_id!r} has unknown panels {unknown}; choose from {list(PANEL_IDS)}"
            )
        burn = deep_merge(
            {"enabled": True, "period_sec": 180, "pixels": 8},
            raw.get("burn_in") or {},
        )
        map_opts = deep_merge(
            {
                "spots": True,
                "labels": True,
                "greyline": True,
                "home": True,
                "sun": True,
                "graticule": True,
            },
            raw.get("map") or {},
        )
        normalized.append(
            {
                "id": page_id,
                "title": str(raw.get("title") or page_id),
                "slug": slug,
                "panels": [item for item in PANEL_IDS if item in panels],
                "dx_rows": max(1, int(raw.get("dx_rows", 10))),
                "show_vhf": bool(raw.get("show_vhf", True)),
                "map": map_opts,
                "burn_in": {
                    "enabled": bool(burn.get("enabled", True)),
                    "period_sec": max(30, int(burn.get("period_sec", 180))),
                    "pixels": max(0, int(burn.get("pixels", 8))),
                },
            }
        )
    return normalized


def resolve_station(cfg: dict) -> dict:
    station = cfg["station"]
    lat = station.get("latitude")
    lon = station.get("longitude")
    grid = (station.get("grid") or "").strip()
    try:
        if lat is None or lon is None:
            if not grid:
                raise ConfigError("station needs a grid square or latitude and longitude")
            lat, lon = grid_to_latlon(grid)
            grid_text = format_grid(grid)
        else:
            lat, lon = float(lat), float(lon)
            grid_text = format_grid(grid) if grid else latlon_to_grid(lat, lon)
    except (GridError, TypeError, ValueError) as exc:
        raise ConfigError(str(exc)) from exc
    call = str(station.get("callsign") or "K0JNM").strip().upper() or "K0JNM"
    timezone = str(station.get("timezone") or "UTC").strip() or "UTC"
    return {
        "callsign": call,
        "grid": grid_text,
        "lat": round(lat, 5),
        "lon": round(lon, 5),
        "timezone": timezone,
    }


def _validate_numbers(cfg: dict) -> None:
    port = cfg["server"]["port"]
    if not isinstance(port, int) or not 0 <= port <= 65535:
        raise ConfigError("server.port must be an integer from 0 to 65535 (0 picks a free port)")
    host = str(cfg["server"]["host"] or "").strip()
    if not host:
        raise ConfigError("server.host is empty")
    cfg["server"]["host"] = host
    cfg["server"]["base_path"] = normalize_base_path(cfg["server"].get("base_path"))
    interval = cfg["publish"].get("status_interval_sec", 15)
    try:
        interval = int(interval)
    except (TypeError, ValueError) as exc:
        raise ConfigError("publish.status_interval_sec must be a number") from exc
    cfg["publish"]["status_interval_sec"] = max(5, interval)
    feeds = cfg["feeds"]
    if feeds.get("dx_longitude") not in ("west-positive", "east-positive"):
        raise ConfigError("feeds.dx_longitude must be 'west-positive' or 'east-positive'")
    for key in ("space_weather_sec", "bands_sec", "dx_sec", "timeout_sec", "dx_max_age_min", "dx_max_spots"):
        try:
            feeds[key] = int(feeds[key])
        except (TypeError, ValueError, KeyError) as exc:
            raise ConfigError(f"feeds.{key} must be a number") from exc
    try:
        feeds["telnet_port"] = int(feeds.get("telnet_port", 7373))
    except (TypeError, ValueError) as exc:
        raise ConfigError("feeds.telnet_port must be a number") from exc


_PUBLISH_ROOTS = {
    Path("/"),
    Path("/etc"),
    Path("/usr"),
    Path("/bin"),
    Path("/sbin"),
    Path("/System"),
    Path("/private"),
    Path("/var"),
    Path("/opt"),
    Path("/Users"),
    Path("/home"),
    Path("/Library"),
    Path("/Applications"),
}


def _reject_publish_root(path: Path) -> None:
    if path in _PUBLISH_ROOTS or path.parent == Path("/") and path.name in {"etc", "usr", "bin", "System", "Library"}:
        raise ConfigError(
            f"{path} is too broad to publish into. Choose a dedicated folder, for example {path}/greyline."
        )


def _normalize_publish(cfg: dict) -> None:
    publish = cfg["publish"]
    raw_targets = publish.get("targets") or []
    if raw_targets is None:
        raw_targets = []
    if not isinstance(raw_targets, list):
        raise ConfigError("publish.targets must be a list")
    legacy = str(publish.get("directory") or "").strip()
    entries = list(raw_targets)
    if legacy and not any(
        isinstance(item, dict) and str(item.get("directory") or "").strip() == legacy for item in entries
    ):
        entries.insert(0, {"directory": legacy, "enabled": bool(publish.get("enabled"))})
    targets = []
    seen: set[str] = set()
    for item in entries:
        if not isinstance(item, dict):
            raise ConfigError("each publish target must be an object")
        directory = str(item.get("directory") or "").strip()
        if not directory:
            continue
        path = Path(directory).expanduser()
        if not path.is_absolute():
            raise ConfigError(f"publish directory must be an absolute path: {directory}")
        _reject_publish_root(path)
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        targets.append({"directory": key, "enabled": bool(item.get("enabled", True))})
    asked = bool(publish.get("enabled"))
    enabled = [item["directory"] for item in targets if item["enabled"]]
    if asked and not enabled and not targets:
        raise ConfigError("publish.enabled is true but publish.directory is empty")
    publish["targets"] = targets
    publish["enabled"] = bool(enabled)
    publish["directory"] = enabled[0] if enabled else (targets[0]["directory"] if targets else "")


def _normalize_dx_filter(cfg: dict) -> None:
    from greyline_hub.layout import DX_BANDS, DX_MODES

    raw = cfg.get("dx_filter") or {}
    if not isinstance(raw, dict):
        raise ConfigError("dx_filter must be an object")
    bands = raw.get("bands") or []
    modes = raw.get("modes") or []
    if not isinstance(bands, list) or not isinstance(modes, list):
        raise ConfigError("dx_filter.bands and dx_filter.modes must be lists")
    clean_bands = []
    for band in bands:
        text = str(band).strip()
        if text not in DX_BANDS:
            raise ConfigError(f"unknown DX band {text!r}")
        if text not in clean_bands:
            clean_bands.append(text)
    clean_modes = []
    allowed = {mode.upper(): mode for mode in DX_MODES}
    for mode in modes:
        text = str(mode).strip().upper()
        if text not in allowed:
            raise ConfigError(f"unknown DX mode {mode!r}")
        if allowed[text] not in clean_modes:
            clean_modes.append(allowed[text])
    try:
        count = int(raw.get("max_count", 60))
    except (TypeError, ValueError) as exc:
        raise ConfigError("dx_filter.max_count must be a number") from exc
    cfg["dx_filter"] = {
        "bands": clean_bands,
        "modes": clean_modes,
        "max_count": max(1, min(60, count)),
    }


def _normalize_config_api(cfg: dict) -> None:
    raw = cfg.get("config_api") or {}
    if not isinstance(raw, dict):
        raise ConfigError("config_api must be an object")
    cfg["config_api"] = {"lan_writes": bool(raw.get("lan_writes", False))}


def enabled_publish_directories(cfg: dict) -> list[Path]:
    paths = []
    for item in cfg.get("publish", {}).get("targets") or []:
        if item.get("enabled") and item.get("directory"):
            paths.append(Path(item["directory"]))
    directory = str(cfg.get("publish", {}).get("directory") or "").strip()
    if cfg.get("publish", {}).get("enabled") and directory:
        path = Path(directory)
        if path not in paths:
            paths.insert(0, path)
    return paths


def prepare(raw: dict) -> dict:
    has_layout = isinstance(raw, dict) and isinstance(raw.get("layout"), dict)
    cfg = deep_merge(DEFAULTS, raw)
    _validate_numbers(cfg)
    cfg["pages"] = normalize_pages(cfg.get("pages") or [])
    _normalize_publish(cfg)
    _normalize_dx_filter(cfg)
    _normalize_config_api(cfg)
    if has_layout:
        from greyline_hub.layout import apply_layout

        apply_layout(cfg)
    cfg["station_resolved"] = resolve_station(cfg)
    clients = cfg.get("clients") or []
    if not isinstance(clients, list):
        raise ConfigError("clients must be a list")
    page_ids = {page["id"] for page in cfg["pages"]}
    cleaned = []
    for client in clients:
        if not isinstance(client, dict):
            continue
        page = str(client.get("page") or "")
        if page and page not in page_ids:
            raise ConfigError(f"client {client.get('name')!r} points at unknown page {page!r}")
        cleaned.append({"name": str(client.get("name") or "client"), "page": page})
    cfg["clients"] = cleaned
    if cfg["publish"]["enabled"] and not str(cfg["publish"].get("directory") or "").strip():
        raise ConfigError("publish.enabled is true but publish.directory is empty")
    if not cfg["server"]["enabled"] and not cfg["publish"]["enabled"]:
        raise ConfigError(
            "nothing to do: enable server, or enable publish and set a directory "
            "your existing web server already serves"
        )
    return cfg


def load_config(path: Path) -> tuple[dict, Path, bool]:
    """Return (config, path, used_example). ``used_example`` is true when no config.json exists."""
    text = path.read_text(encoding="utf-8")
    try:
        raw = json.loads(strip_json_comments(text))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError(f"{path} must contain a JSON object")
    used_example = path.name == "config.example.json"
    return prepare(raw), path, used_example


def discover_config(explicit: str | None = None) -> tuple[dict, Path, bool]:
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise ConfigError(f"config not found: {path}")
        return load_config(path)
    env = os.environ.get("GREYLINE_CONFIG")
    if env:
        path = Path(env).expanduser()
        if not path.is_file():
            raise ConfigError(f"GREYLINE_CONFIG does not exist: {path}")
        return load_config(path)
    for candidate in (Path.cwd() / "config.json", ROOT / "config.json"):
        if candidate.is_file():
            return load_config(candidate)
    example = ROOT / "config.example.json"
    if example.is_file():
        return load_config(example)
    return prepare({}), ROOT / "config.json", True
