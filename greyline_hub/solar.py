"""Solar geometry for the greyline.

The formulas follow the NOAA solar calculator (public domain): Julian century,
geometric mean longitude and anomaly, equation of center, obliquity, declination,
and the equation of time. They are accurate to well under a degree, which is
plenty for a world-map terminator.

Longitude is positive east. The subsolar point is where the sun is overhead.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone

# Station is "on the greyline" while the sun is between these elevations.
GREYLINE_HIGH = 6.0
GREYLINE_LOW = -12.0


def _julian_century(dt: datetime) -> float:
    dt = dt.astimezone(timezone.utc)
    year, month = dt.year, dt.month
    if month <= 2:
        year -= 1
        month += 12
    a = year // 100
    b = 2 - a + a // 4
    day = (
        dt.day
        + dt.hour / 24.0
        + dt.minute / 1440.0
        + dt.second / 86400.0
        + dt.microsecond / 86400.0 / 1e6
    )
    jd = int(365.25 * (year + 4716)) + int(30.6001 * (month + 1)) + day + b - 1524.5
    return (jd - 2451545.0) / 36525.0


def _wrap180(deg: float) -> float:
    return ((deg + 180.0) % 360.0) - 180.0


def solar_position(dt: datetime) -> dict:
    """Declination, subsolar longitude (east-positive), and equation of time (minutes)."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    t = _julian_century(dt)
    l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360.0
    m = (357.52911 + t * (35999.05029 - 0.0001537 * t)) % 360.0
    e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    mr = math.radians(m)
    c = (
        math.sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
        + math.sin(2 * mr) * (0.019993 - 0.000101 * t)
        + math.sin(3 * mr) * 0.000289
    )
    true_long = l0 + c
    omega = 125.04 - 1934.136 * t
    lam = true_long - 0.00569 - 0.00478 * math.sin(math.radians(omega))
    eps0 = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0
    eps = eps0 + 0.00256 * math.cos(math.radians(omega))
    decl = math.degrees(math.asin(math.sin(math.radians(eps)) * math.sin(math.radians(lam))))

    y = math.tan(math.radians(eps) / 2.0) ** 2
    l0r = math.radians(l0)
    eqtime = 4.0 * math.degrees(
        y * math.sin(2 * l0r)
        - 2 * e * math.sin(mr)
        + 4 * e * y * math.sin(mr) * math.cos(2 * l0r)
        - 0.5 * y * y * math.sin(4 * l0r)
        - 1.25 * e * e * math.sin(2 * mr)
    )

    hours = dt.hour + dt.minute / 60.0 + dt.second / 3600.0 + dt.microsecond / 3.6e9
    # At 12:00 UTC the sun is near the prime meridian; positive equation of time
    # (sundial ahead of the clock) puts the subsolar point slightly west.
    sub_lon = -15.0 * (hours - 12.0) - eqtime / 4.0
    return {
        "declination": decl,
        "subsolar_latitude": decl,
        "subsolar_longitude": _wrap180(sub_lon),
        "eqtime_minutes": eqtime,
    }


def elevation(lat: float, lon: float, decl: float, sub_lon: float) -> float:
    """Solar elevation in degrees at one place. Positive means the sun is up."""
    ha = math.radians(lon - sub_lon)
    dec = math.radians(decl)
    la = math.radians(lat)
    sin_elev = math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(ha)
    sin_elev = max(-1.0, min(1.0, sin_elev))
    return math.degrees(math.asin(sin_elev))


def daylight_state(elev: float | None) -> str:
    if elev is None:
        return "unknown"
    if GREYLINE_LOW <= elev <= GREYLINE_HIGH:
        return "greyline"
    if elev > GREYLINE_HIGH:
        return "day"
    return "night"


def _crossing(decl: float, sub_lon: float, lon: float, alpha: float) -> float | None:
    """Latitude where solar elevation equals ``alpha``, or None if that meridian misses it."""
    prev_e = None
    prev_lat = None
    for lat in range(-90, 91):
        e = elevation(lat, lon, decl, sub_lon) - alpha
        if prev_e is not None and prev_e * e < 0:
            frac = abs(prev_e) / (abs(prev_e) + abs(e))
            return prev_lat + frac * (lat - prev_lat)
        prev_e = e
        prev_lat = float(lat)
    return None


def terminator_grid(decl: float, sub_lon: float, step: int = 2) -> dict:
    """Sample the day/night boundary.

    ``day`` is the latitude of elevation 0. ``twi`` is elevation -6° (civil twilight),
    used to paint the grey band. ``fill`` is "night" or "day" when a meridian never
    crosses the terminator (equinox noon/midnight, or polar day/night). ``night_south``
    is true when the night side of a crossing lies toward the south pole.
    """
    day: list[float | None] = []
    twi: list[float | None] = []
    fill: list[str] = []
    lon = -180
    while lon <= 180:
        d = _crossing(decl, sub_lon, lon, 0.0)
        t = _crossing(decl, sub_lon, lon, -6.0)
        day.append(None if d is None else round(d, 2))
        twi.append(None if t is None else round(t, 2))
        if d is None:
            fill.append("night" if elevation(0.0, lon, decl, sub_lon) < 0 else "day")
        else:
            fill.append("")
        lon += step
    return {
        "step": step,
        "day": day,
        "twi": twi,
        "fill": fill,
        "night_south": decl >= 0,
    }


def sunrise_sunset(lat: float, lon: float, when: datetime) -> tuple[datetime | None, datetime | None]:
    """UTC sunrise and sunset for the UTC date of ``when``. None during polar day or night.

    Uses a solar depression of 0.833° so refraction and the solar radius are included,
    which matches ordinary published sunrise times.
    """
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    pos = solar_position(when)
    decl = pos["declination"]
    eqtime = pos["eqtime_minutes"]
    alpha = math.radians(-0.833)
    latr = math.radians(lat)
    decr = math.radians(decl)
    denom = math.cos(latr) * math.cos(decr)
    if abs(denom) < 1e-9:
        return None, None
    cos_ha = (math.sin(alpha) - math.sin(latr) * math.sin(decr)) / denom
    if cos_ha < -1.0 or cos_ha > 1.0:
        return None, None
    ha = math.degrees(math.acos(cos_ha))

    def _at(sub_lon: float) -> datetime:
        hours = 12.0 + (-_wrap180(sub_lon) - eqtime / 4.0) / 15.0
        base = datetime(when.year, when.month, when.day, tzinfo=timezone.utc)
        return base + timedelta(hours=hours)

    # Hour angle is negative at sunrise: subsolar longitude = station longitude - ha.
    return _at(lon + ha), _at(lon - ha)
