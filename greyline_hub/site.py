"""Write the dashboard site.

The built-in server and a folder on an existing web server both serve this tree.
Links are relative, so the folder can live at any URL path. ``status.json`` is the
file the pages poll; it is replaced atomically.
"""

from __future__ import annotations

import html
import json
import os
import shutil
from pathlib import Path

from greyline_hub.paths import LAND_PATH, STATIC_DIR

_MARKER = ".greyline-hub"


class PublishError(RuntimeError):
    pass


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _atomic_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def _prefix(depth: int) -> str:
    return "../" * depth


def render_dashboard(page: dict, depth: int) -> str:
    prefix = _prefix(depth)
    title = html.escape(page["title"])
    page_id = html.escape(page["id"])
    pages_href = html.escape(f"{prefix}pages/")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{title} · Greyline Hub</title>
<meta name="greyline-page" content="{page_id}">
<meta name="greyline-status" content="{prefix}data/status.json">
<meta name="greyline-world" content="{prefix}assets/land.geojson">
<meta name="greyline-pages" content="{pages_href}">
<link rel="stylesheet" href="{prefix}assets/app.css">
</head>
<body data-page="{page_id}">
<div id="stage">
  <div id="banner" hidden></div>
  <header id="top"></header>
  <div id="columns">
    <section id="map-panel"><canvas id="map"></canvas><div id="legend"></div></section>
    <aside id="side"></aside>
  </div>
  <section id="dx"></section>
  <footer id="statusline"></footer>
</div>
<script src="{prefix}assets/app.js"></script>
</body>
</html>
"""


def render_directory(cfg: dict, depth: int) -> str:
    prefix = _prefix(depth)
    by_page: dict[str, list[str]] = {}
    for client in cfg.get("clients") or []:
        by_page.setdefault(client["page"], []).append(client["name"])
    rows = []
    for page in cfg["pages"]:
        href = f"{prefix}" if not page["slug"] else f"{prefix}{page['slug']}/"
        path = "/" if not page["slug"] else f"/{page['slug']}/"
        clients = ", ".join(by_page.get(page["id"], [])) or "—"
        panels = ", ".join(page["panels"])
        rows.append(
            "<li>"
            f"<a href=\"{html.escape(href)}\"><code>{html.escape(path)}</code> "
            f"{html.escape(page['title'])}</a>"
            f"<span class=\"meta\">{html.escape(panels)}</span>"
            f"<span class=\"meta\">clients: {html.escape(clients)}</span>"
            "</li>"
        )
    base = html.escape(cfg["server"].get("base_path") or "")
    port = html.escape(str(cfg["server"]["port"]))
    notes = []
    if cfg["server"]["enabled"]:
        where = f" on port {port}"
        if base:
            where += f" under {base}"
        notes.append(f"The built-in server listens{where}.")
    if cfg["publish"]["enabled"]:
        notes.append("The same pages are written into the publish folder for the web server you already run.")
    if not notes:
        notes.append("Point each screensaver at one path below.")
    lead = " ".join(notes) + " Changing panels in config.json updates these pages without editing HTML."
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Greyline Hub pages</title>
<link rel="stylesheet" href="{prefix}assets/app.css">
</head>
<body class="directory">
<main class="directory-card">
  <p class="eyebrow">Greyline Hub</p>
  <h1>Pages</h1>
  <p class="lead">{html.escape(lead)}</p>
  <ul class="page-list">
    {"".join(rows)}
  </ul>
</main>
</body>
</html>
"""


def assert_publish_directory(directory: Path) -> None:
    """Refuse to overwrite an unrelated site if the folder is not ours."""
    index = directory / "index.html"
    if not index.is_file():
        return
    try:
        text = index.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise PublishError(f"cannot read {index}: {exc}") from exc
    if "greyline-page" in text or "Greyline Hub pages" in text:
        return
    raise PublishError(
        f"{directory} already contains an index.html that is not a Greyline Hub page. "
        "Set publish.directory to a dedicated folder, for example /var/www/html/greyline."
    )


class Site:
    def __init__(
        self,
        directory: Path,
        publish_directory: Path | None = None,
        extra_publish: list[Path] | None = None,
    ):
        self.directory = Path(directory)
        seen: list[Path] = []
        for candidate in [publish_directory, *(extra_publish or [])]:
            if candidate is None:
                continue
            path = Path(candidate).expanduser()
            if path not in seen:
                seen.append(path)
        self.publish_directories = seen
        self._signature: tuple | None = None

    def rebuild(self, cfg: dict, force: bool = False) -> None:
        signature = (
            json.dumps(cfg["pages"], sort_keys=True),
            json.dumps(cfg["clients"], sort_keys=True),
            cfg["server"]["port"],
            cfg["server"]["base_path"],
        )
        if signature == self._signature and not force and (self.directory / "assets" / "app.js").is_file():
            return
        self._write_tree(self.directory, cfg)
        self._signature = signature
        for directory in self.publish_directories:
            try:
                assert_publish_directory(directory)
                self._write_tree(directory, cfg)
            except PublishError as exc:
                import logging

                logging.getLogger("greyline").error("%s", exc)

    def write_status(self, status: dict) -> None:
        body = json.dumps(status, separators=(",", ":")).encode("utf-8")
        health = json.dumps(
            {"ok": True, "service": "greyline-hub", "time": status.get("server_time")}
        ).encode("utf-8")
        for root in [self.directory, *self.publish_directories]:
            try:
                _atomic_write(root / "data" / "status.json", body)
                _atomic_write(root / "health.json", health)
            except OSError as exc:
                import logging

                logging.getLogger("greyline").error("could not write %s: %s", root, exc)

    def _write_tree(self, root: Path, cfg: dict) -> None:
        root.mkdir(parents=True, exist_ok=True)
        assets = root / "assets"
        assets.mkdir(parents=True, exist_ok=True)
        for name in ("app.css", "app.js"):
            _atomic_copy(STATIC_DIR / name, assets / name)
        _atomic_copy(LAND_PATH, assets / "land.geojson")

        slugs = set()
        root_page = None
        for page in cfg["pages"]:
            if page["slug"]:
                folder = root / page["slug"]
                _atomic_write(folder / "index.html", render_dashboard(page, 1).encode("utf-8"))
                _atomic_write(folder / _MARKER, page["id"].encode("utf-8"))
                slugs.add(page["slug"])
            else:
                root_page = page
        if root_page is not None:
            _atomic_write(root / "index.html", render_dashboard(root_page, 0).encode("utf-8"))
        else:
            _atomic_write(root / "index.html", render_directory(cfg, 0).encode("utf-8"))

        pages_dir = root / "pages"
        _atomic_write(pages_dir / "index.html", render_directory(cfg, 1).encode("utf-8"))
        _atomic_write(pages_dir / _MARKER, b"pages")
        self._prune(root, slugs)

    def _prune(self, root: Path, keep_slugs: set[str]) -> None:
        if not root.is_dir():
            return
        for child in root.iterdir():
            if not child.is_dir() or child.name in keep_slugs or child.name in {"assets", "data", "pages"}:
                continue
            if (child / _MARKER).is_file():
                shutil.rmtree(child)
