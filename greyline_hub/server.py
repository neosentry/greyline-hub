"""Small static server for the generated site.

``server.port`` chooses the port so Greyline Hub can run beside other web
servers. ``server.base_path`` mounts the site under a prefix when a reverse
proxy does not strip one. Folder mode does not need this process to listen
at all; it only writes files.
"""

from __future__ import annotations

import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

log = logging.getLogger("greyline")

_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".geojson": "application/geo+json; charset=utf-8",
}


def make_handler(site_dir: Path, base_path: str, hooks=None):
    root = site_dir.resolve()
    base = base_path.rstrip("/")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):  # noqa: N802 - stdlib name
            self._serve()

        def do_HEAD(self):  # noqa: N802 - stdlib name
            self._serve(head_only=True)

        def do_POST(self):  # noqa: N802 - stdlib name
            path = self._strip(unquote(urlsplit(self.path).path))
            if path is None:
                self._send(404, b"not found\n", "text/plain; charset=utf-8", False)
                return
            if hooks is not None and hooks.handle(self, "POST", path):
                return
            self._send(404, b"not found\n", "text/plain; charset=utf-8", False)

        def _strip(self, path: str) -> str | None:
            if base:
                if path == base:
                    return "/"
                if path.startswith(base + "/"):
                    return path[len(base):] or "/"
                return None
            return path

        def _serve(self, head_only: bool = False) -> None:
            path = self._strip(unquote(urlsplit(self.path).path))
            if path is None:
                self._send(404, b"not found\n", "text/plain; charset=utf-8", head_only)
                return
            if hooks is not None and hooks.handle(self, "HEAD" if head_only else "GET", path, head_only):
                return
            if path in ("/api/health", "/health.json"):
                target = root / "health.json"
                if target.is_file():
                    self._send_file(target, head_only)
                    return
                self._send(200, b'{"ok":true,"ready":false}\n', "application/json", head_only)
                return
            if path == "/api/status":
                path = "/data/status.json"
            relative = path.lstrip("/")
            if relative in ("", "."):
                relative = "index.html"
            candidate = (root / relative).resolve()
            if candidate.is_dir():
                candidate = (candidate / "index.html").resolve()
            if root != candidate and root not in candidate.parents:
                self._send(403, b"forbidden\n", "text/plain; charset=utf-8", head_only)
                return
            if not candidate.is_file():
                self._send(404, b"not found\n", "text/plain; charset=utf-8", head_only)
                return
            self._send_file(candidate, head_only)

        def _send_file(self, path: Path, head_only: bool) -> None:
            body = path.read_bytes()
            kind = _TYPES.get(path.suffix.lower(), "application/octet-stream")
            # The dashboard and its assets change when config or the program is updated.
            # A long cache would leave a screensaver on yesterday's page.
            self._send(200, body, kind, head_only, no_store=True)

        def _send(self, code: int, body: bytes, content_type: str, head_only: bool, no_store: bool = True) -> None:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store" if no_store else "public, max-age=300")
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
            if not head_only:
                self.wfile.write(body)

        def log_message(self, fmt: str, *args) -> None:
            log.debug("%s " + fmt, self.address_string(), *args)

    return Handler


class HubServer:
    def __init__(self, host: str, port: int, base_path: str, site_dir: Path, hooks=None):
        handler = make_handler(site_dir, base_path, hooks)
        try:
            self.httpd = ThreadingHTTPServer((host, port), handler)
        except OSError as exc:
            raise SystemExit(
                f"could not listen on {host}:{port} ({exc}). "
                "Set server.port to a free port, or set server.enabled to false and "
                "publish into a folder your existing web server already serves."
            ) from exc
        self.host = host
        self.port = self.httpd.server_address[1]

    def serve_forever(self) -> None:
        self.httpd.serve_forever(poll_interval=0.5)

    def shutdown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
