"""Layout presets and the document the screen saver reads.

``regions`` is a 12-column grid. The current saver still decides pixel sizes
from the panel list and the preset name. A later editor can move regions
without inventing a second schema: same ids, same rows and columns.
"""

from __future__ import annotations

PANEL_IDS = ("clock", "map", "space_weather", "bands", "dx_spots")

PRESETS: dict[str, dict] = {
    "shack": {
        "panels": ["clock", "map", "space_weather", "bands", "dx_spots"],
        "dx_rows": 10,
        "regions": [
            {"id": "header", "panel": "clock", "row": 0, "col": 0, "rows": 1, "cols": 12},
            {"id": "map", "panel": "map", "row": 1, "col": 0, "rows": 6, "cols": 8},
            {"id": "weather", "panel": "space_weather", "row": 1, "col": 8, "rows": 3, "cols": 4},
            {"id": "bands", "panel": "bands", "row": 4, "col": 8, "rows": 3, "cols": 4},
            {"id": "spots", "panel": "dx_spots", "row": 7, "col": 0, "rows": 3, "cols": 12},
        ],
    },
    "map-heavy": {
        "panels": ["clock", "map", "dx_spots"],
        "dx_rows": 4,
        "regions": [
            {"id": "header", "panel": "clock", "row": 0, "col": 0, "rows": 1, "cols": 12},
            {"id": "map", "panel": "map", "row": 1, "col": 0, "rows": 8, "cols": 12},
            {"id": "spots", "panel": "dx_spots", "row": 9, "col": 0, "rows": 2, "cols": 12},
        ],
    },
    "spots-heavy": {
        "panels": ["clock", "map", "space_weather", "dx_spots"],
        "dx_rows": 18,
        "regions": [
            {"id": "header", "panel": "clock", "row": 0, "col": 0, "rows": 1, "cols": 12},
            {"id": "spots", "panel": "dx_spots", "row": 1, "col": 0, "rows": 6, "cols": 8},
            {"id": "weather", "panel": "space_weather", "row": 1, "col": 8, "rows": 3, "cols": 4},
            {"id": "map", "panel": "map", "row": 4, "col": 8, "rows": 3, "cols": 4},
            {"id": "map-wide", "panel": "map", "row": 7, "col": 0, "rows": 3, "cols": 8},
        ],
    },
}

DX_BANDS = (
    "160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "2m", "70cm",
)
DX_MODES = ("CW", "SSB", "USB", "LSB", "FT8", "FT4", "RTTY", "PSK31", "FM", "AM", "DIGI", "JS8")


def main_page(pages: list[dict]) -> dict:
    for page in pages:
        if page.get("id") == "main":
            return page
    for page in pages:
        if not page.get("slug"):
            return page
    return pages[0]


def regions_for(preset: str, panels: list[str]) -> list[dict]:
    """Grid regions for the panels that are actually on."""
    spec = PRESETS.get(preset) or PRESETS["shack"]
    wanted = set(panels)
    regions = [dict(item) for item in spec["regions"] if item["panel"] in wanted]
    if regions:
        return regions
    row = 0
    built = []
    for panel in PANEL_IDS:
        if panel not in wanted:
            continue
        built.append({"id": panel, "panel": panel, "row": row, "col": 0, "rows": 2, "cols": 12})
        row += 2
    return built


def apply_layout(cfg: dict) -> None:
    """Copy a layout block onto the main page. Called only when the file set one."""
    from greyline_hub.config import ConfigError

    layout = cfg.get("layout") or {}
    preset = str(layout.get("preset") or "shack").strip()
    if preset not in PRESETS and preset != "custom":
        raise ConfigError("layout.preset must be shack, map-heavy, spots-heavy, or custom")
    if preset == "custom":
        chosen = layout.get("panels") or list(PANEL_IDS)
        if not isinstance(chosen, list):
            raise ConfigError("layout.panels must be a list")
        unknown = [item for item in chosen if item not in PANEL_IDS]
        if unknown:
            raise ConfigError(f"unknown panels {unknown}")
        panels = [panel for panel in PANEL_IDS if panel in chosen]
    else:
        panels = list(PRESETS[preset]["panels"])
    if not panels:
        raise ConfigError("choose at least one panel")
    if "dx_rows" in layout and layout.get("dx_rows") is not None:
        try:
            dx_rows = int(layout["dx_rows"])
        except (TypeError, ValueError) as exc:
            raise ConfigError("layout.dx_rows must be a number") from exc
    elif preset in PRESETS:
        dx_rows = int(PRESETS[preset]["dx_rows"])
    else:
        dx_rows = 10
    dx_rows = max(1, min(60, dx_rows))
    page = main_page(cfg["pages"])
    page["panels"] = panels
    page["dx_rows"] = dx_rows
    cfg["layout"] = {
        "preset": preset,
        "panels": panels,
        "dx_rows": dx_rows,
        "regions": regions_for(preset if preset in PRESETS else "shack", panels),
    }


def infer_preset(panels: list[str], dx_rows: int) -> str:
    ordered = [panel for panel in PANEL_IDS if panel in panels]
    for name, spec in PRESETS.items():
        if list(spec["panels"]) == ordered and int(spec["dx_rows"]) == int(dx_rows):
            return name
    return "custom"


def layout_document(cfg: dict) -> dict:
    """Settings file published next to status.json. Schema version 1."""
    page = main_page(cfg["pages"])
    stored = cfg.get("layout") if isinstance(cfg.get("layout"), dict) else {}
    preset = str(stored.get("preset") or infer_preset(page["panels"], page["dx_rows"]))
    panels = [panel for panel in PANEL_IDS if panel in page["panels"]]
    dx_filter = cfg.get("dx_filter") or {}
    station = cfg["station_resolved"]
    return {
        "schema": 1,
        "preset": preset,
        "panels": panels,
        "dx_rows": int(page["dx_rows"]),
        "regions": regions_for(preset if preset in PRESETS else "shack", panels),
        "dx_filter": {
            "bands": list(dx_filter.get("bands") or []),
            "modes": list(dx_filter.get("modes") or []),
            "max_count": int(dx_filter.get("max_count") or page["dx_rows"]),
        },
        "station": {
            "callsign": station["callsign"],
            "grid": station["grid"],
            "lat": station["lat"],
            "lon": station["lon"],
            "timezone": station["timezone"],
        },
        "map": page.get("map") or {},
        "burn_in": page.get("burn_in") or {},
    }


def filter_spots(spots: list[dict], dx_filter: dict | None, limit: int) -> list[dict]:
    filt = dx_filter or {}
    bands = {str(item) for item in filt.get("bands") or [] if str(item).strip()}
    modes = {str(item).upper() for item in filt.get("modes") or [] if str(item).strip()}
    kept = []
    for spot in spots:
        if bands and str(spot.get("band") or "") not in bands:
            continue
        mode = str(spot.get("mode") or "").upper()
        if modes and mode not in modes:
            continue
        kept.append(spot)
    cap = int(filt.get("max_count") or limit)
    cap = max(1, min(60, cap, int(limit)))
    return kept[:cap]
