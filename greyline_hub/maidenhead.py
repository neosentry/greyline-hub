"""Maidenhead locator conversion.

Grid squares are the usual amateur-radio way to write a station location.
The center of the square is used so a marker lands in the middle of the cell.
"""

from __future__ import annotations


class GridError(ValueError):
    pass


_FIELDS = "ABCDEFGHIJKLMNOPQR"


def format_grid(grid: str) -> str:
    raw = "".join(grid.split()).strip()
    if len(raw) < 2:
        raise GridError(f"grid square is too short: {grid!r}")
    out = raw[:2].upper()
    if len(raw) >= 4:
        out += raw[2:4]
    if len(raw) >= 6:
        out += raw[4:6].lower()
    if len(raw) > 6:
        out += raw[6:].upper()
    return out


def grid_to_latlon(grid: str) -> tuple[float, float]:
    """Return (latitude, longitude) in degrees, longitude positive east."""
    g = format_grid(grid)
    if len(g) not in (2, 4, 6, 8) or not g[0].isalpha() or not g[1].isalpha():
        raise GridError(f"not a Maidenhead grid: {grid!r}")
    if g[0] not in _FIELDS or g[1] not in _FIELDS:
        raise GridError(f"grid field is out of range: {grid!r}")

    lon = (ord(g[0]) - ord("A")) * 20 - 180
    lat = (ord(g[1]) - ord("A")) * 10 - 90
    if len(g) == 2:
        return lat + 5.0, lon + 10.0

    if not (g[2].isdigit() and g[3].isdigit()):
        raise GridError(f"grid square digits are missing: {grid!r}")
    lon += int(g[2]) * 2
    lat += int(g[3])
    if len(g) == 4:
        return lat + 0.5, lon + 1.0

    if not (g[4].isalpha() and g[5].isalpha()):
        raise GridError(f"grid subsquare is invalid: {grid!r}")
    sub_lon = (ord(g[4].upper()) - ord("A")) * (2.0 / 24.0)
    sub_lat = (ord(g[5].upper()) - ord("A")) * (1.0 / 24.0)
    if g[4].upper() not in _FIELDS or g[5].upper() not in _FIELDS:
        raise GridError(f"grid subsquare is out of range: {grid!r}")
    lon += sub_lon
    lat += sub_lat
    if len(g) == 6:
        return lat + (1.0 / 48.0), lon + (2.0 / 48.0)

    if not (g[6].isdigit() and g[7].isdigit()):
        raise GridError(f"extended grid is invalid: {grid!r}")
    lon += int(g[6]) * (2.0 / 240.0)
    lat += int(g[7]) * (1.0 / 240.0)
    return lat + (1.0 / 480.0), lon + (2.0 / 480.0)


def latlon_to_grid(lat: float, lon: float, precision: int = 6) -> str:
    """Encode a coordinate. ``precision`` is 4 or 6 characters."""
    if precision not in (4, 6):
        raise GridError("precision must be 4 or 6")
    lat = max(-89.999999, min(89.999999, float(lat)))
    lon = ((float(lon) + 180.0) % 360.0) - 180.0
    lon_n = lon + 180.0
    lat_n = lat + 90.0
    grid = _FIELDS[int(lon_n // 20)] + _FIELDS[int(lat_n // 10)]
    lon_n %= 20
    lat_n %= 10
    grid += str(int(lon_n // 2)) + str(int(lat_n // 1))
    if precision == 4:
        return grid
    lon_n %= 2
    lat_n %= 1
    grid += _FIELDS[int(lon_n // (2.0 / 24.0))].lower()
    grid += _FIELDS[int(lat_n // (1.0 / 24.0))].lower()
    return grid
