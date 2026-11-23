"""Fetch and normalize the public feeds.

Each function stores a small payload in the cache. Parsers never touch the
network, so tests can feed them fixtures. Fetchers keep the previous payload
when a source is down.
"""

from __future__ import annotations

import json
import logging
import socket
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from greyline_hub import __version__
from greyline_hub.cache import FeedCache
from greyline_hub.cty import CountryFile
from greyline_hub.spots import (
    normalize_http_spot,
    parse_telnet_line,
    spot_is_fresh,
    xray_class,
)

log = logging.getLogger("greyline")

URL_SFI = "https://services.swpc.noaa.gov/products/summary/10cm-flux.json"
URL_KP = "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json"
URL_XRAY = "https://services.swpc.noaa.gov/json/goes/primary/xrays-6-hour.json"
URL_WIND = "https://services.swpc.noaa.gov/products/summary/solar-wind-speed.json"
URL_MAG = "https://services.swpc.noaa.gov/products/summary/solar-wind-mag-field.json"
URL_SCALES = "https://services.swpc.noaa.gov/products/noaa-scales.json"
URL_EISN = "https://www.sidc.be/SILSO/DATA/EISN/EISN_current.txt"
URL_HAMQSL = (
    "https://www.hamqsl.com/solarxml.php",
    "http://www.hamqsl.com/solarxml.php",
)

_UA = f"GreylineHub/{__version__} (personal amateur radio dashboard; one cached fetch)"


def http_get(url: str, timeout: float) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": _UA, "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _loads(raw: bytes | str):
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    return json.loads(raw)


def _stamp(value: str | None) -> str | None:
    if not value:
        return None
    text = value.strip().replace("Z", "")
    if "T" not in text and " " in text:
        text = text.replace(" ", "T", 1)
    if text.endswith("Z"):
        return text
    return text + "Z"


def parse_sfi(raw: bytes | str) -> dict | None:
    data = _loads(raw)
    row = data[-1] if isinstance(data, list) and data else data
    if not isinstance(row, dict) or row.get("flux") is None:
        return None
    return {"value": float(row["flux"]), "at": _stamp(str(row.get("time_tag") or "")), "source": "NOAA SWPC 10.7 cm"}


def parse_kp(raw: bytes | str) -> dict | None:
    data = _loads(raw)
    if not isinstance(data, list) or not data:
        return None
    row = data[-1]
    if isinstance(row, dict):
        kp = row.get("Kp", row.get("kp"))
        ap = row.get("a_running", row.get("ap"))
        when = row.get("time_tag")
    elif isinstance(row, list):
        body = data
        if body and isinstance(body[0], list) and body[0] and str(body[0][0]) == "time_tag":
            body = body[1:]
        if not body or len(body[-1]) < 3:
            return None
        when, kp, ap = body[-1][0], body[-1][1], body[-1][2]
    else:
        return None
    if kp is None:
        return None
    return {
        "kp": float(kp),
        "ap": None if ap is None else float(ap),
        "at": _stamp(str(when or "")),
        "source": "NOAA SWPC",
    }


def parse_xray(raw: bytes | str) -> dict | None:
    data = _loads(raw)
    if not isinstance(data, list):
        return None
    chosen = None
    for row in reversed(data):
        if isinstance(row, dict) and row.get("energy") == "0.1-0.8nm" and row.get("flux") is not None:
            chosen = row
            break
    if not chosen:
        return None
    flux = float(chosen["flux"])
    return {
        "value": xray_class(flux),
        "flux": flux,
        "at": _stamp(str(chosen.get("time_tag") or "")),
        "source": "NOAA SWPC GOES 0.1-0.8 nm",
    }


def parse_wind(raw: bytes | str) -> dict | None:
    data = _loads(raw)
    row = data[-1] if isinstance(data, list) and data else data
    if not isinstance(row, dict) or row.get("proton_speed") is None:
        return None
    return {
        "value": float(row["proton_speed"]),
        "at": _stamp(str(row.get("time_tag") or "")),
        "source": "NOAA SWPC",
    }


def parse_mag(raw: bytes | str) -> dict | None:
    data = _loads(raw)
    row = data[-1] if isinstance(data, list) and data else data
    if not isinstance(row, dict):
        return None
    if row.get("bz_gsm") is None and row.get("bt") is None:
        return None
    return {
        "bz": None if row.get("bz_gsm") is None else float(row["bz_gsm"]),
        "bt": None if row.get("bt") is None else float(row["bt"]),
        "at": _stamp(str(row.get("time_tag") or "")),
        "source": "NOAA SWPC",
    }


def parse_scales(raw: bytes | str) -> dict | None:
    data = _loads(raw)
    current = data.get("0") if isinstance(data, dict) else None
    if not isinstance(current, dict):
        return None
    def scale(key: str) -> str | None:
        block = current.get(key) or {}
        value = block.get("Scale")
        return None if value is None else str(value)

    return {
        "R": scale("R"),
        "S": scale("S"),
        "G": scale("G"),
        "at": _stamp(f"{current.get('DateStamp', '')}T{current.get('TimeStamp', '')}"),
        "source": "NOAA SWPC scales",
    }


def parse_eisn(raw: bytes | str) -> dict | None:
    text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw
    last = None
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0].isdigit() and parts[1].isdigit():
            last = parts
    if not last:
        return None
    year, month, day = int(last[0]), int(last[1]), int(last[2])
    return {
        "value": float(last[4]),
        "at": f"{year:04d}-{month:02d}-{day:02d}T00:00:00Z",
        "source": "SIDC EISN",
    }


def _float_text(value: str | None) -> float | None:
    if value is None:
        return None
    text = value.strip()
    if not text or text.lower() in {"norpt", "no report", "null"}:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_hamqsl(raw: bytes | str) -> dict | None:
    text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return None
    data = root.find("solardata")
    if data is None:
        return None

    def text_of(tag: str) -> str:
        node = data.find(tag)
        return (node.text or "").strip() if node is not None and node.text else ""

    bands: dict[str, dict] = {}
    for node in data.findall("./calculatedconditions/band"):
        name = (node.get("name") or "").strip()
        when = (node.get("time") or "").strip().lower()
        if not name or when not in {"day", "night"}:
            continue
        bands.setdefault(name, {"name": name, "day": None, "night": None})
        bands[name][when] = (node.text or "").strip() or None
    vhf = []
    for node in data.findall("./calculatedvhfconditions/phenomenon"):
        vhf.append(
            {
                "name": (node.get("name") or "").strip(),
                "location": (node.get("location") or "").strip(),
                "condition": (node.text or "").strip(),
            }
        )
    muf = _float_text(text_of("muf"))
    return {
        "updated": text_of("updated"),
        "solarflux": _float_text(text_of("solarflux")),
        "aindex": _float_text(text_of("aindex")),
        "kindex": _float_text(text_of("kindex")),
        "sunspots": _float_text(text_of("sunspots")),
        "xray": text_of("xray") or None,
        "solarwind": _float_text(text_of("solarwind")),
        "magneticfield": _float_text(text_of("magneticfield")),
        "geomagfield": text_of("geomagfield") or None,
        "signalnoise": text_of("signalnoise") or None,
        "muf": muf,
        "bands": list(bands.values()),
        "vhf": vhf,
        "source": "N0NBH hamqsl.com",
    }


def parse_dx_http(raw: bytes | str, longitude: str) -> list[dict]:
    data = _loads(raw)
    if isinstance(data, dict):
        data = data.get("spots") or data.get("data") or []
    spots = []
    if not isinstance(data, list):
        return spots
    for row in data:
        if isinstance(row, dict):
            spot = normalize_http_spot(row, longitude)
            if spot:
                spots.append(spot)
    return spots


def estimate_bands(sfi: float | None, kp: float | None) -> list[dict]:
    """A coarse desk estimate used only when the N0NBH band feed is unavailable.

    It is not a path prediction. High solar flux favors the high bands; a high
    K index knocks every estimate down a step.
    """
    flux = 70.0 if sfi is None else sfi
    index = 0.0 if kp is None else kp

    def level(base: int) -> str:
        if index >= 6:
            base -= 2
        elif index >= 4:
            base -= 1
        base = max(0, min(2, base))
        return ("Poor", "Fair", "Good")[base]

    if flux >= 150:
        table = {
            "80m-40m": (1, 2),
            "30m-20m": (2, 2),
            "17m-15m": (2, 1),
            "12m-10m": (2, 0),
        }
    elif flux >= 110:
        table = {
            "80m-40m": (1, 2),
            "30m-20m": (2, 2),
            "17m-15m": (1, 1),
            "12m-10m": (1, 0),
        }
    else:
        table = {
            "80m-40m": (2, 2),
            "30m-20m": (1, 1),
            "17m-15m": (0, 0),
            "12m-10m": (0, 0),
        }
    return [
        {"name": name, "day": level(day), "night": level(night)}
        for name, (day, night) in table.items()
    ]


def _store(cache: FeedCache, key: str, producer) -> None:
    try:
        payload = producer()
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ET.ParseError, OSError, ValueError) as exc:
        log.warning("%s: %s", key, exc)
        cache.fail(key, str(exc))
        return
    if payload is None:
        cache.fail(key, "empty response")
        return
    cache.put(key, payload)


def collect_space_weather(cache: FeedCache, timeout: float) -> None:
    jobs = {
        "sw_sfi": (URL_SFI, parse_sfi),
        "sw_kp": (URL_KP, parse_kp),
        "sw_xray": (URL_XRAY, parse_xray),
        "sw_wind": (URL_WIND, parse_wind),
        "sw_mag": (URL_MAG, parse_mag),
        "sw_scales": (URL_SCALES, parse_scales),
        "sw_ssn": (URL_EISN, parse_eisn),
    }

    def one(item) -> None:
        key, (url, parser) = item
        _store(cache, key, lambda: parser(http_get(url, timeout)))

    with ThreadPoolExecutor(max_workers=7) as pool:
        list(pool.map(one, jobs.items()))


def collect_bands(cache: FeedCache, timeout: float) -> None:
    def producer():
        last_error = None
        for url in URL_HAMQSL:
            try:
                parsed = parse_hamqsl(http_get(url, timeout))
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last_error = exc
                continue
            if parsed is None:
                last_error = ValueError(f"could not parse {url}")
                continue
            return parsed
        if last_error:
            raise last_error
        return None

    _store(cache, "hamqsl", producer)


def collect_dx(cache: FeedCache, timeout: float, url: str, longitude: str) -> None:
    _store(cache, "dx_http", lambda: parse_dx_http(http_get(url, timeout), longitude))


class TelnetSpots:
    """One reconnecting session to a DX cluster. Disabled unless configured."""

    def __init__(self, host: str, port: int, login: str, max_age_min: float):
        self.host = host
        self.port = port
        self.login = login
        self.max_age_min = max_age_min
        self._lock = threading.Lock()
        self._spots: list[dict] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.connected = False
        self.last_error: str | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, name="greyline-dx-telnet", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self._spots)

    def _remember(self, spot: dict) -> None:
        now = datetime.now(timezone.utc)
        with self._lock:
            self._spots.append(spot)
            self._spots = [item for item in self._spots if spot_is_fresh(item, now, self.max_age_min)]
            if len(self._spots) > 200:
                self._spots = self._spots[-200:]

    def _loop(self) -> None:
        delay = 5
        while not self._stop.is_set():
            try:
                self._session()
                delay = 5
            except (OSError, TimeoutError) as exc:
                self.connected = False
                self.last_error = str(exc)
                log.warning("dx telnet %s:%s: %s", self.host, self.port, exc)
            if self._stop.wait(delay):
                return
            delay = min(60, delay * 2)

    def _session(self) -> None:
        log.info("dx telnet connecting to %s:%s as %s", self.host, self.port, self.login)
        with socket.create_connection((self.host, self.port), timeout=10) as sock:
            sock.settimeout(30)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            except OSError:
                pass
            self.connected = True
            self.last_error = None
            logged_in = False
            started = time.time()
            buffer = b""
            while not self._stop.is_set():
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    if time.time() - started > 90:
                        sock.sendall(b"\r\n")
                        started = time.time()
                    continue
                if not chunk:
                    self.connected = False
                    return
                buffer += chunk
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    text = raw.decode("latin-1", errors="replace").strip("\r")
                    if not logged_in:
                        low = text.lower()
                        if any(word in low for word in ("login", "callsign", "call:")):
                            sock.sendall((self.login + "\r\n").encode("ascii", errors="replace"))
                            logged_in = True
                    spot = parse_telnet_line(text, datetime.now(timezone.utc))
                    if spot:
                        self._remember(spot)
                if not logged_in and time.time() - started > 2:
                    sock.sendall((self.login + "\r\n").encode("ascii", errors="replace"))
                    logged_in = True


def locate_spot(spot: dict, countries: CountryFile | None) -> dict:
    if spot.get("lat") is not None and spot.get("lon") is not None:
        return spot
    if countries is None:
        return spot
    place = countries.lookup_call(spot.get("dx") or "")
    if place is None:
        return spot
    updated = dict(spot)
    updated["lat"] = place.lat
    updated["lon"] = place.lon
    if not updated.get("country"):
        updated["country"] = place.name
    return updated
