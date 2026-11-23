"""Assemble the document every dashboard page reads.

Missing feeds become null fields plus a stale/empty flag. The clock, the station,
and the greyline do not depend on any external feed, so the map still draws.
"""

from __future__ import annotations

import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from greyline_hub.cache import FeedCache
from greyline_hub.cty import CountryFile
from greyline_hub.feeds import estimate_bands, locate_spot
from greyline_hub.solar import daylight_state, elevation, solar_position, sunrise_sunset, terminator_grid
from greyline_hub.spots import spot_is_fresh


def _slot(cache: FeedCache, key: str) -> dict | None:
    return cache.get(key)


def _payload(slot: dict | None):
    if not slot:
        return None
    return slot.get("payload")


def _age(slot: dict | None, now: float) -> int | None:
    if not slot or not slot.get("fetched_at"):
        return None
    return max(0, int(now - slot["fetched_at"]))


def _fresh(slot: dict | None, now: float, max_age: float) -> bool:
    if not slot or slot.get("payload") is None or not slot.get("fetched_at"):
        return False
    if slot.get("error"):
        return False
    return (now - slot["fetched_at"]) <= max_age


def _field(value, at, source) -> dict:
    return {"value": value, "at": at, "source": source}


def _first(*pairs):
    """First (value, at, source) whose value is not None."""
    for value, at, source in pairs:
        if value is not None and value != "":
            return value, at, source
    return None, None, None


def _fmt_hhmm(dt: datetime | None, zone: ZoneInfo | None = None) -> str | None:
    if dt is None:
        return None
    if zone is not None:
        dt = dt.astimezone(zone)
    return dt.strftime("%H:%M")


def build_status(cfg: dict, cache: FeedCache, countries: CountryFile | None, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    now_ts = now.timestamp()
    station = cfg["station_resolved"]
    feeds = cfg["feeds"]
    sw_max = max(feeds["space_weather_sec"] * 3, 1800)
    band_max = max(feeds["bands_sec"] * 3, 3600)
    dx_max = max(feeds["dx_sec"] * 5, 300)

    sfi_slot = _slot(cache, "sw_sfi")
    ssn_slot = _slot(cache, "sw_ssn")
    kp_slot = _slot(cache, "sw_kp")
    xray_slot = _slot(cache, "sw_xray")
    wind_slot = _slot(cache, "sw_wind")
    mag_slot = _slot(cache, "sw_mag")
    scales_slot = _slot(cache, "sw_scales")
    ham_slot = _slot(cache, "hamqsl")
    dx_slot = _slot(cache, "dx_http")
    telnet_slot = _slot(cache, "dx_telnet")

    sfi = _payload(sfi_slot) or {}
    ssn = _payload(ssn_slot) or {}
    kp = _payload(kp_slot) or {}
    xray = _payload(xray_slot) or {}
    wind = _payload(wind_slot) or {}
    mag = _payload(mag_slot) or {}
    scales = _payload(scales_slot) or {}
    ham = _payload(ham_slot) or {}

    sfi_v, sfi_at, sfi_src = _first(
        (sfi.get("value"), sfi.get("at"), sfi.get("source")),
        (ham.get("solarflux"), ham.get("updated"), ham.get("source")),
    )
    ssn_v, ssn_at, ssn_src = _first(
        (ssn.get("value"), ssn.get("at"), ssn.get("source")),
        (ham.get("sunspots"), ham.get("updated"), ham.get("source")),
    )
    kp_v, kp_at, kp_src = _first(
        (kp.get("kp"), kp.get("at"), kp.get("source")),
        (ham.get("kindex"), ham.get("updated"), ham.get("source")),
    )
    # Daily A from N0NBH. The NOAA value is the running 3-hour ap, used only as a fallback.
    a_v, a_at, a_src = _first(
        (ham.get("aindex"), ham.get("updated"), "N0NBH daily A"),
        (kp.get("ap"), kp.get("at"), "NOAA SWPC ap (3-hour)"),
    )
    x_v, x_at, x_src = _first(
        (xray.get("value"), xray.get("at"), xray.get("source")),
        (ham.get("xray"), ham.get("updated"), ham.get("source")),
    )
    wind_v, wind_at, wind_src = _first(
        (wind.get("value"), wind.get("at"), wind.get("source")),
        (ham.get("solarwind"), ham.get("updated"), ham.get("source")),
    )
    bz_v, bz_at, bz_src = _first(
        (mag.get("bz"), mag.get("at"), mag.get("source")),
        (ham.get("magneticfield"), ham.get("updated"), ham.get("source")),
    )

    sw_slots = (sfi_slot, ssn_slot, kp_slot, xray_slot, wind_slot, mag_slot, scales_slot, ham_slot)
    sw_has = any(_payload(slot) is not None for slot in sw_slots)
    sw_ok = any(_fresh(slot, now_ts, sw_max) for slot in sw_slots)
    sw_ages = [age for age in (_age(slot, now_ts) for slot in sw_slots) if age is not None]
    sw_errors = {key: slot.get("error") for key, slot in (
        ("sfi", sfi_slot),
        ("ssn", ssn_slot),
        ("kp", kp_slot),
        ("xray", xray_slot),
        ("wind", wind_slot),
        ("mag", mag_slot),
        ("scales", scales_slot),
        ("bands", ham_slot),
    ) if slot and slot.get("error")}

    bands = ham.get("bands") or []
    bands_estimated = False
    if not bands and (sfi_v is not None or kp_v is not None):
        bands = estimate_bands(sfi_v, kp_v)
        bands_estimated = True
    bands_ok = _fresh(ham_slot, now_ts, band_max) or (bands_estimated and sw_ok)
    bands_has = bool(bands)

    http_spots = list(_payload(dx_slot) or [])
    telnet_spots = list(_payload(telnet_slot) or [])
    merged = []
    seen = set()
    for spot in http_spots + telnet_spots:
        if not spot_is_fresh(spot, now, feeds["dx_max_age_min"]):
            continue
        key = (spot.get("dx"), round(float(spot.get("freq_khz") or 0), 1), spot.get("time"))
        if key in seen:
            continue
        seen.add(key)
        merged.append(locate_spot(spot, countries))
    merged.sort(key=lambda item: item.get("time") or "", reverse=True)
    from greyline_hub.layout import filter_spots

    merged = filter_spots(merged, cfg.get("dx_filter"), int(feeds["dx_max_spots"]))
    sources = []
    if http_spots:
        sources.append("DX Summit")
    if telnet_spots:
        sources.append(f"telnet {feeds.get('telnet_host')}")
    dx_ok = _fresh(dx_slot, now_ts, dx_max) or _fresh(telnet_slot, now_ts, dx_max)
    dx_has = bool(merged) or _payload(dx_slot) is not None or _payload(telnet_slot) is not None

    solar = solar_position(now)
    grid = terminator_grid(solar["declination"], solar["subsolar_longitude"])
    elev = elevation(station["lat"], station["lon"], solar["declination"], solar["subsolar_longitude"])
    sunrise, sunset = sunrise_sunset(station["lat"], station["lon"], now)
    try:
        zone = ZoneInfo(station["timezone"])
    except Exception:
        zone = timezone.utc

    def feed_report(name: str, ok: bool, has: bool, age: int | None, error: str | None, source: str) -> dict:
        return {
            "name": name,
            "ok": ok,
            "empty": not has,
            "stale": bool(has and not ok),
            "age_sec": age,
            "error": error,
            "source": source,
        }

    dx_age_candidates = [age for age in (_age(dx_slot, now_ts), _age(telnet_slot, now_ts)) if age is not None]
    dx_error = None
    for slot in (dx_slot, telnet_slot):
        if slot and slot.get("error"):
            dx_error = slot["error"]

    return {
        "service": "greyline-hub",
        "server_time": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "station": {
            **station,
            "solar_elevation": round(elev, 1),
            "daylight": daylight_state(elev),
            "sunrise_utc": _fmt_hhmm(sunrise),
            "sunset_utc": _fmt_hhmm(sunset),
            "sunrise_local": _fmt_hhmm(sunrise, zone),
            "sunset_local": _fmt_hhmm(sunset, zone),
        },
        "solar": {
            "declination": round(solar["declination"], 3),
            "subsolar_latitude": round(solar["subsolar_latitude"], 3),
            "subsolar_longitude": round(solar["subsolar_longitude"], 3),
            "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "grid": grid,
        },
        "space_weather": {
            "sfi": _field(None if sfi_v is None else round(float(sfi_v), 1), sfi_at, sfi_src),
            "ssn": _field(None if ssn_v is None else round(float(ssn_v), 1), ssn_at, ssn_src),
            "kp": _field(None if kp_v is None else round(float(kp_v), 2), kp_at, kp_src),
            "a": _field(None if a_v is None else round(float(a_v), 1), a_at, a_src),
            "xray": _field(x_v, x_at, x_src),
            "solar_wind": _field(None if wind_v is None else round(float(wind_v), 1), wind_at, wind_src),
            "bz": _field(None if bz_v is None else round(float(bz_v), 1), bz_at, bz_src),
            "scales": {"R": scales.get("R"), "S": scales.get("S"), "G": scales.get("G")},
            "geomag": ham.get("geomagfield"),
            "noise": ham.get("signalnoise"),
            "muf": ham.get("muf"),
            "stale": bool(sw_has and not sw_ok),
            "empty": not sw_has,
            "age_sec": min(sw_ages) if sw_ages else None,
        },
        "bands": {
            "rows": bands,
            "vhf": ham.get("vhf") or [],
            "estimated": bands_estimated,
            "source": "Estimated from SFI and Kp" if bands_estimated else (ham.get("source") if bands else None),
            "stale": bool(bands_has and not bands_ok),
            "empty": not bands_has,
            "age_sec": _age(ham_slot, now_ts),
        },
        "spots": {
            "items": merged,
            "count": len(merged),
            "source": " + ".join(sources) if sources else None,
            "stale": bool(dx_has and not dx_ok),
            "empty": not merged,
            "age_sec": min(dx_age_candidates) if dx_age_candidates else None,
        },
        "feeds": {
            "space_weather": feed_report(
                "Space weather",
                sw_ok,
                sw_has,
                min(sw_ages) if sw_ages else None,
                "; ".join(f"{key}: {msg}" for key, msg in sw_errors.items()) or None,
                "NOAA SWPC, SIDC, N0NBH",
            ),
            "bands": feed_report(
                "Bands",
                bool(bands_ok),
                bands_has,
                _age(ham_slot, now_ts),
                (ham_slot or {}).get("error") if ham_slot else None,
                "N0NBH" if not bands_estimated else "SFI/Kp estimate",
            ),
            "dx": feed_report(
                "DX spots",
                bool(dx_ok),
                bool(merged),
                min(dx_age_candidates) if dx_age_candidates else None,
                dx_error,
                " + ".join(sources) if sources else "DX Summit",
            ),
        },
        "pages": cfg["pages"],
        "clients": cfg["clients"],
        "paths": {
            page["id"]: ("/" if not page["slug"] else f"/{page['slug']}/")
            for page in cfg["pages"]
        },
    }
