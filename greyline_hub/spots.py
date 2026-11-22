"""DX cluster spot normalization.

DX Summit publishes latitude and a longitude that is positive west (the same
convention as cty.dat). Telnet cluster lines carry no coordinates; the caller
fills those in from the country file.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

# Inclusive kHz ranges. A few kilohertz of slack covers off-band FT8 spots.
_BANDS: tuple[tuple[float, float, str], ...] = (
    (1800, 2000, "160m"),
    (3500, 4000, "80m"),
    (5300, 5450, "60m"),
    (7000, 7300, "40m"),
    (10100, 10150, "30m"),
    (14000, 14350, "20m"),
    (18068, 18168, "17m"),
    (21000, 21450, "15m"),
    (24890, 24990, "12m"),
    (28000, 29700, "10m"),
    (50000, 54000, "6m"),
    (144000, 148000, "2m"),
    (420000, 450000, "70cm"),
)

_MODE = re.compile(
    r"\b(FT8|FT4|JS8|JT65|JT9|MSK144|Q65|OLIVIA|RTTY|PSK31|PSK63|SSTV|USB|LSB|SSB|CW|FM|AM|DIGI)\b",
    re.IGNORECASE,
)
_DX_LINE = re.compile(
    r"^DX de\s+([A-Z0-9/\-]+):\s+([0-9.]+)\s+([A-Z0-9/]+)\s*(.*?)\s+(\d{4})Z\b",
    re.IGNORECASE,
)
_TRAIL = re.compile(r"[-][@#]$")


def band_for_khz(freq_khz: float) -> str | None:
    for lo, hi, name in _BANDS:
        if lo <= freq_khz <= hi:
            return name
    return None


def mode_from_text(text: str | None) -> str | None:
    if not text:
        return None
    found = [m.group(1).upper() for m in _MODE.finditer(text)]
    if not found:
        return None
    # USB/LSB are more specific than a bare SSB mention in a contest name.
    for preferred in ("USB", "LSB", "FT8", "FT4", "CW", "RTTY"):
        if preferred in found:
            return preferred
    return found[0]


def clean_call(call: str) -> str:
    return _TRAIL.sub("", call.strip())


def as_utc_iso(value: str | None) -> str | None:
    if not value:
        return None
    text = value.strip().replace(" ", "T")
    if text.endswith("Z") or re.search(r"[+-]\d\d:?\d\d$", text):
        return text
    return text + "Z"


def hhmm_to_iso(hhmm: str, now: datetime) -> str:
    now = now.astimezone(timezone.utc)
    hour, minute = int(hhmm[:2]), int(hhmm[2:])
    stamp = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if stamp - now > timedelta(hours=2):
        stamp -= timedelta(days=1)
    return stamp.strftime("%Y-%m-%dT%H:%M:%SZ")


def _number(value) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def east_longitude(value, convention: str) -> float | None:
    lon = _number(value)
    if lon is None:
        return None
    if convention == "west-positive":
        return -lon
    return lon


def normalize_http_spot(raw: dict, longitude: str = "west-positive") -> dict | None:
    dx = clean_call(str(raw.get("dx_call") or raw.get("dx_callsign") or ""))
    freq = _number(raw.get("frequency") or raw.get("freq"))
    if not dx or freq is None:
        return None
    info = raw.get("info") or raw.get("comment") or ""
    if info is None:
        info = ""
    info = str(info).strip()
    spotter = clean_call(str(raw.get("de_call") or raw.get("spotter_callsign") or raw.get("spotter") or ""))
    return {
        "id": str(raw.get("id") or raw.get("spot_id") or f"{dx}:{freq}"),
        "dx": dx,
        "freq_khz": freq,
        "band": band_for_khz(freq),
        "mode": mode_from_text(info),
        "comment": info,
        "spotter": spotter,
        "time": as_utc_iso(str(raw.get("time") or raw.get("dx_time") or "")) ,
        "lat": _number(raw.get("dx_latitude") or raw.get("dx_lat")),
        "lon": east_longitude(raw.get("dx_longitude") if "dx_longitude" in raw else raw.get("dx_lon"), longitude),
        "country": (raw.get("dx_country") or "") or None,
        "source": "dxsummit",
    }


def parse_telnet_line(line: str, now: datetime) -> dict | None:
    match = _DX_LINE.search(line.strip())
    if not match:
        return None
    spotter, freq_s, dx, comment, hhmm = match.groups()
    try:
        freq = float(freq_s)
    except ValueError:
        return None
    comment = " ".join(comment.split())
    return {
        "id": f"telnet:{hhmm}:{dx}:{freq}",
        "dx": clean_call(dx),
        "freq_khz": freq,
        "band": band_for_khz(freq),
        "mode": mode_from_text(comment),
        "comment": comment,
        "spotter": clean_call(spotter),
        "time": hhmm_to_iso(hhmm, now),
        "lat": None,
        "lon": None,
        "country": None,
        "source": "telnet",
    }


def spot_is_fresh(spot: dict, now: datetime, max_age_min: float) -> bool:
    text = spot.get("time")
    if not text:
        return False
    try:
        stamp = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return False
    age = now.astimezone(timezone.utc) - stamp.astimezone(timezone.utc)
    return timedelta(minutes=-5) <= age <= timedelta(minutes=max_age_min)


def xray_class(flux: float) -> str:
    """GOES 0.1–0.8 nm flux in W/m² to the A/B/C/M/X scale."""
    if flux <= 0:
        return "A0.0"
    thresholds = ((1e-4, "X"), (1e-5, "M"), (1e-6, "C"), (1e-7, "B"), (1e-8, "A"))
    for limit, letter in thresholds:
        if flux >= limit:
            return f"{letter}{flux / limit:.1f}"
    return f"A{flux / 1e-8:.1f}"
