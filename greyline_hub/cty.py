"""Prefix locations from the AD1C cty.dat country file.

cty.dat stores longitude positive west. This module converts to positive east,
which is what the map uses. A spot from a telnet cluster has no coordinates;
the longest matching prefix is the location drawn on the map.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Place:
    name: str
    continent: str
    lat: float
    lon: float
    prefix: str


# Operating suffixes that do not change the DXCC entity.
_SUFFIXES = {"P", "M", "MM", "AM", "QRP", "A", "PM", "MM"}

_OVERRIDE = re.compile(r"[\(\[<{~]")


class CountryFile:
    def __init__(self, exact: dict[str, Place], prefixes: dict[str, Place]):
        self.exact = exact
        self.prefixes = prefixes

    def lookup_call(self, call: str) -> Place | None:
        target = location_call(call)
        if not target:
            return None
        found = self.exact.get(target)
        if found:
            return found
        for length in range(len(target), 0, -1):
            found = self.prefixes.get(target[:length])
            if found:
                return found
        return None


def location_call(dx: str) -> str:
    """Pick the part of a portable callsign that names the place being operated.

    ``EA8/DL1ABC`` and ``DL1ABC/EA8`` are both the Canaries. ``DL1ABC/P`` stays in Germany.
    """
    parts = []
    for raw in dx.upper().replace(" ", "").split("/"):
        if raw and raw not in _SUFFIXES:
            parts.append(raw)
    if not parts:
        return ""
    if len(parts) == 1:
        return parts[0]

    def full_call(token: str) -> bool:
        return len(token) >= 4 and any(ch.isdigit() for ch in token)

    first, last = parts[0], parts[-1]
    if full_call(first) and not full_call(last):
        return last
    if full_call(last) and not full_call(first):
        return first
    return first if len(first) <= len(last) else last


def _alias_prefix(token: str) -> tuple[bool, str]:
    exact = token.startswith("=")
    body = token[1:] if exact else token
    body = _OVERRIDE.split(body, maxsplit=1)[0]
    return exact, body.upper()


def parse_cty(text: str) -> CountryFile:
    exact: dict[str, Place] = {}
    prefixes: dict[str, Place] = {}
    current: Place | None = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0].isspace():
            if current is None:
                continue
            raw = line.strip().rstrip(";").rstrip(",")
            for token in raw.split(","):
                token = token.strip()
                if not token:
                    continue
                is_exact, prefix = _alias_prefix(token)
                if not prefix:
                    continue
                if is_exact:
                    exact[prefix] = current
                else:
                    prefixes[prefix] = current
            continue
        parts = [part.strip() for part in line.split(":")]
        if len(parts) < 8:
            continue
        try:
            lat = float(parts[4])
            lon_west = float(parts[5])
        except ValueError:
            continue
        current = Place(
            name=parts[0],
            continent=parts[3],
            lat=lat,
            lon=-lon_west,
            prefix=parts[7],
        )
        if current.prefix:
            prefixes[current.prefix.upper()] = current
    return CountryFile(exact, prefixes)


def load_cty(path: Path) -> CountryFile:
    return parse_cty(path.read_text(encoding="utf-8", errors="replace"))
