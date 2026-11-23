"""Local configuration page and the JSON API behind it.

Writes are accepted from 127.0.0.1 and ::1 unless config_api.lan_writes is
true. The dashboard pages are unchanged: this only guards /config and /api/config.
"""

from __future__ import annotations

import copy
import json
import os
import re
import socket
import ssl
from pathlib import Path
from zoneinfo import ZoneInfo

from greyline_hub.config import ConfigError, prepare, strip_json_comments
from greyline_hub.layout import DX_BANDS, DX_MODES, infer_preset, layout_document, main_page
from greyline_hub.maidenhead import GridError, format_grid, grid_to_latlon
from greyline_hub.paths import STATIC_DIR

_CALL = re.compile(r"[A-Z0-9/]{3,16}")
_LOCAL = {"127.0.0.1", "::1", "localhost"}
_PROBE_PORTS = (80, 8080, 8000, 8888, 3000, 8081, 443, 8443)
_PAGE = (STATIC_DIR / "config.html").read_text(encoding="utf-8")


def client_is_local(address) -> bool:
    host = address[0] if address else ""
    if host.startswith("::ffff:"):
        host = host[7:]
    return host in _LOCAL


def read_raw(path: Path) -> dict:
    if not path.is_file():
        return {}
    data = json.loads(strip_json_comments(path.read_text(encoding="utf-8")))
    if not isinstance(data, dict):
        raise ConfigError(f"{path} must contain a JSON object")
    return data


def save_config_file(path: Path, raw: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(raw, indent=2) + "\n").encode("utf-8")
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(payload)
    os.replace(tmp, path)


def _callsign(value) -> str:
    call = str(value or "").strip().upper()
    if not _CALL.fullmatch(call):
        raise ConfigError("callsign must be 3–16 letters, numbers, or slashes")
    return call


def _timezone(value) -> str:
    name = str(value or "").strip()
    if not name or len(name) > 64:
        raise ConfigError("timezone is required")
    try:
        ZoneInfo(name)
    except Exception as exc:
        raise ConfigError(f"unknown timezone {name}") from exc
    return name


def _grid(value) -> tuple[str, float, float]:
    try:
        grid = format_grid(str(value or ""))
        if len(grid) not in (4, 6, 8):
            raise GridError("use a 4, 6, or 8 character grid")
        lat, lon = grid_to_latlon(grid)
    except GridError as exc:
        raise ConfigError(str(exc)) from exc
    return grid, round(lat, 5), round(lon, 5)


def apply_form(existing: dict, form: dict) -> dict:
    """Merge a config-page submission into the on-disk JSON and validate it."""
    if not isinstance(form, dict):
        raise ConfigError("configuration must be a JSON object")
    raw = copy.deepcopy(existing) if isinstance(existing, dict) else {}
    station = form.get("station") or {}
    if not isinstance(station, dict):
        raise ConfigError("station must be an object")
    grid, lat, lon = _grid(station.get("grid"))
    raw["station"] = {
        "callsign": _callsign(station.get("callsign")),
        "grid": grid,
        "latitude": lat,
        "longitude": lon,
        "timezone": _timezone(station.get("timezone")),
    }
    server = form.get("server") or {}
    if not isinstance(server, dict):
        raise ConfigError("server must be an object")
    try:
        port = int(server.get("port"))
    except (TypeError, ValueError) as exc:
        raise ConfigError("port must be a number from 1 to 65535") from exc
    if not 1 <= port <= 65535:
        raise ConfigError("port must be a number from 1 to 65535")
    raw.setdefault("server", {})
    raw["server"]["port"] = port
    raw["server"]["enabled"] = bool(server.get("enabled", True))

    submitted = form.get("publish") or []
    if not isinstance(submitted, list):
        raise ConfigError("publish must be a list")
    targets = []
    for item in submitted:
        if not isinstance(item, dict):
            raise ConfigError("each publish target must be an object")
        directory = str(item.get("directory") or "").strip()
        if not directory:
            continue
        targets.append({"directory": directory, "enabled": bool(item.get("enabled", True))})
    previous = raw.get("publish") if isinstance(raw.get("publish"), dict) else {}
    enabled = any(item["enabled"] for item in targets)
    raw["publish"] = {
        "enabled": enabled,
        "directory": next((item["directory"] for item in targets if item["enabled"]), ""),
        "targets": targets,
        "status_interval_sec": previous.get("status_interval_sec", 15),
    }

    layout = form.get("layout") or {}
    if not isinstance(layout, dict):
        raise ConfigError("layout must be an object")
    dx_filter = form.get("dx_filter") or {}
    if not isinstance(dx_filter, dict):
        raise ConfigError("dx_filter must be an object")
    raw["layout"] = {
        "preset": str(layout.get("preset") or "custom"),
        "panels": layout.get("panels") or [],
        "dx_rows": layout.get("dx_rows", dx_filter.get("max_count", 10)),
    }
    raw["dx_filter"] = {
        "bands": dx_filter.get("bands") or [],
        "modes": dx_filter.get("modes") or [],
        "max_count": dx_filter.get("max_count", raw["layout"]["dx_rows"]),
    }
    raw.setdefault("config_api", {})
    if not isinstance(raw["config_api"], dict):
        raw["config_api"] = {}
    raw["config_api"]["lan_writes"] = bool(form.get("lan_writes"))
    if isinstance(form.get("linux"), dict):
        raw["linux"] = form["linux"]
    prepare(raw)
    return raw


def public_document(service) -> dict:
    cfg = service.cfg
    page = main_page(cfg["pages"])
    station = cfg["station_resolved"]
    stored = cfg.get("layout") if isinstance(cfg.get("layout"), dict) else {}
    preset = str(stored.get("preset") or infer_preset(page["panels"], page["dx_rows"]))
    listening = service.server.port if getattr(service, "server", None) else None
    configured = int(cfg["server"]["port"])
    restart = listening is not None and (configured != int(listening) or not cfg["server"]["enabled"])
    return {
        "station": {
            "callsign": station["callsign"],
            "grid": station["grid"],
            "lat": station["lat"],
            "lon": station["lon"],
            "timezone": station["timezone"],
        },
        "server": {
            "enabled": bool(cfg["server"]["enabled"]),
            "port": configured,
            "listening_port": listening,
            "restart_required": restart,
        },
        "publish": {
            "enabled": bool(cfg["publish"]["enabled"]),
            "directory": cfg["publish"].get("directory") or "",
            "targets": list(cfg["publish"].get("targets") or []),
        },
        "layout": {
            "preset": preset,
            "panels": list(page["panels"]),
            "dx_rows": int(page["dx_rows"]),
            "regions": layout_document(cfg)["regions"],
        },
        "dx_filter": dict(cfg.get("dx_filter") or {}),
        "lan_writes": bool(cfg.get("config_api", {}).get("lan_writes")),
        "linux": dict(cfg.get("linux") or {}),
        "config_path": str(service.config_path),
        "catalog": {"bands": list(DX_BANDS), "modes": list(DX_MODES)},
    }


def _banner(port: int, tls: bool) -> str | None:
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=0.3)
    except OSError:
        return None
    try:
        if tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            sock = context.wrap_socket(sock, server_hostname="127.0.0.1")
        sock.settimeout(0.4)
        sock.sendall(b"GET / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        data = b""
        while len(data) < 4096:
            chunk = sock.recv(1024)
            if not chunk:
                break
            data += chunk
            if b"\r\n\r\n" in data:
                break
    except OSError:
        return None
    finally:
        try:
            sock.close()
        except OSError:
            pass
    text = data.decode("latin-1", errors="replace")
    if not text.startswith("HTTP/"):
        return ""
    for line in text.split("\r\n"):
        if line.lower().startswith("server:"):
            return line.split(":", 1)[1].strip()
    return ""


def _product(banner: str) -> str:
    low = banner.lower()
    if "nginx" in low:
        return "nginx"
    if "apache" in low or low.startswith("httpd"):
        return "apache"
    if "caddy" in low:
        return "caddy"
    if not banner:
        return "http"
    return banner.split("/", 1)[0].strip() or "http"


def _roots_in(text: str) -> list[Path]:
    found = []
    for match in re.finditer(r"(?m)^\s*root\s+([^;{]+);", text):
        raw = match.group(1).strip().strip("\"'")
        if not raw or "$" in raw or raw.startswith("~"):
            continue
        path = Path(raw)
        if path.is_dir() and path not in found:
            found.append(path)
    return found


def _known_docroots(product: str) -> list[Path]:
    files = []
    if product == "nginx":
        files = [
            Path("/opt/homebrew/etc/nginx/nginx.conf"),
            Path("/usr/local/etc/nginx/nginx.conf"),
            Path("/etc/nginx/nginx.conf"),
        ]
    elif product == "caddy":
        files = [
            Path("/opt/homebrew/etc/Caddyfile"),
            Path("/usr/local/etc/Caddyfile"),
            Path("/etc/caddy/Caddyfile"),
        ]
    roots: list[Path] = []
    for conf in files:
        try:
            roots.extend(_roots_in(conf.read_text(encoding="utf-8", errors="replace")))
        except OSError:
            continue
    candidates = [
        Path("/opt/homebrew/var/www"),
        Path("/usr/local/var/www"),
        Path("/Library/WebServer/Documents"),
        Path("/var/www/html"),
        Path("/usr/share/nginx/html"),
        Path("/srv/http"),
    ]
    for path in candidates:
        if path.is_dir() and path not in roots:
            if product == "apache" and "www" not in str(path) and path.name not in {"Documents", "html", "http"}:
                continue
            roots.append(path)
    if product == "nginx":
        roots = [path for path in roots if path.name != "Documents" or "WebServer" in str(path)]
    return roots


def detect_web_servers(skip_ports: set[int] | None = None) -> list[dict]:
    """Web servers already listening on this machine, plus a folder to publish into."""
    skip = set(skip_ports or ())
    found = []
    for port in _PROBE_PORTS:
        if port in skip:
            continue
        tls = port in {443, 8443}
        banner = _banner(port, tls)
        if banner is None:
            continue
        name = _product(banner)
        if "greyline" in banner.lower():
            continue
        suggested = []
        for root in _known_docroots(name):
            folder = root / "greyline"
            suggested.append(str(folder))
        found.append(
            {
                "port": port,
                "scheme": "https" if tls else "http",
                "banner": banner,
                "name": name,
                "suggested": suggested,
            }
        )
    return found


class ConfigHooks:
    def __init__(self, service):
        self.service = service

    def handle(self, handler, method: str, path: str, head_only: bool = False) -> bool:
        if path not in {"/config", "/config/", "/api/config", "/api/config/servers"}:
            return False
        if not self._allowed(handler):
            if path.startswith("/api/"):
                body = json.dumps(
                    {
                        "ok": False,
                        "error": "Configuration is only accepted from this computer. Open http://127.0.0.1 and the port, then /config/.",
                    }
                ).encode("utf-8")
                handler._send(403, body, "application/json", head_only)
            else:
                handler._send(
                    403,
                    b"Open this page on the same computer: http://127.0.0.1:<port>/config/\n",
                    "text/plain; charset=utf-8",
                    head_only,
                )
            return True
        try:
            if path in {"/config", "/config/"} and method in {"GET", "HEAD"}:
                handler._send(200, _PAGE.encode("utf-8"), "text/html; charset=utf-8", head_only)
                return True
            if path == "/api/config/servers" and method in {"GET", "HEAD"}:
                listening = self.service.server.port if self.service.server else None
                skip = {int(listening)} if listening else set()
                payload = {"ok": True, "servers": detect_web_servers(skip)}
                handler._send(200, json.dumps(payload).encode("utf-8"), "application/json", head_only)
                return True
            if path == "/api/config" and method in {"GET", "HEAD"}:
                payload = {"ok": True, "config": public_document(self.service)}
                handler._send(200, json.dumps(payload).encode("utf-8"), "application/json", head_only)
                return True
            if path == "/api/config" and method == "POST":
                form = _read_json(handler)
                message = self.service.save_from_form(form)
                restart = message["server"]["restart_required"]
                text = "Saved. Restart the server to use the new port." if restart else "Saved."
                payload = {"ok": True, "message": text, "config": message}
                handler._send(200, json.dumps(payload).encode("utf-8"), "application/json", False)
                return True
        except ConfigError as exc:
            body = json.dumps({"ok": False, "error": str(exc)}).encode("utf-8")
            handler._send(400, body, "application/json", head_only)
            return True
        except json.JSONDecodeError:
            body = json.dumps({"ok": False, "error": "the body is not JSON"}).encode("utf-8")
            handler._send(400, body, "application/json", head_only)
            return True
        handler._send(405, b'{"ok":false,"error":"method not allowed"}\n', "application/json", head_only)
        return True

    def _allowed(self, handler) -> bool:
        if client_is_local(handler.client_address):
            return True
        return bool(self.service.cfg.get("config_api", {}).get("lan_writes"))


def _read_json(handler) -> dict:
    try:
        length = int(handler.headers.get("Content-Length") or "0")
    except ValueError as exc:
        raise ConfigError("Content-Length is not a number") from exc
    if length <= 0 or length > 65536:
        raise ConfigError("configuration body is empty or larger than 64KB")
    raw = handler.rfile.read(length)
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ConfigError("configuration body must be a JSON object")
    return data


def writable_config_path(service) -> Path:
    path = Path(service.config_path)
    if path.name == "config.example.json" or not path.is_file():
        return path.with_name("config.json") if path.name == "config.example.json" else path
    return path
