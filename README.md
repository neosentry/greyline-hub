# Greyline Hub

Greyline Hub is a personal amateur-radio dashboard meant to run as a screensaver. A small Python service collects the feeds once, and every screen opens a page. The page is what you configure: which panels, how many spots, the station, and a slow drift so a static display does not burn in.

```bash
python3 greyline-hub
```

That listens on port **8754** and serves the example pages at:

- `http://127.0.0.1:8754/` — clock, world map with the greyline, space weather, HF bands, DX spots
- `http://127.0.0.1:8754/map/` — clock, map, and spots
- `http://127.0.0.1:8754/pages/` — the list of pages and which screen each one is for

Python 3.9 or newer. The standard library is enough; there is nothing to pip install.

Copy `config.example.json` to `config.json` before you leave it running. The example station is K0JNM in grid EL87uu (about 27.85° N, 82.30° W). Edit that block if the map should mark a different station.

## Choose a port

Another program may already own port 80 or 8080. Set `server.port` in `config.json`, or pass it once:

```bash
python3 greyline-hub --port 9000 --host 127.0.0.1
```

`--host 127.0.0.1` keeps it off the LAN. The default host `0.0.0.0` is reachable by the other machines in the house. There is no login on the page, so do not forward the port to the internet.

`server.base_path` mounts the site under a prefix (`/greyline`) when a reverse proxy forwards the full path. Leave it empty when clients open `http://host:8754/` directly, or when the proxy strips the prefix.

## Use the web server you already have

You do not have to give Greyline Hub a port. It can write the pages into a folder and let nginx, Caddy, Apache, or lighttpd serve them.

```json
"server": { "enabled": false },
"publish": {
  "enabled": true,
  "directory": "/var/www/html/greyline"
}
```

```bash
python3 greyline-hub
```

The process only fetches data and rewrites files. `http://your-server/greyline/` is the root page and `http://your-server/greyline/map/` is the other one. Links inside the pages are relative, so the folder can sit anywhere under the web root.

Use a **dedicated** directory. If that folder already contains some other site's `index.html`, Greyline Hub refuses to write there.

You can also do both: listen on 8754 for laptops, and publish into the house web server.

```bash
python3 greyline-hub --port 8754 --publish /var/www/html/greyline
```

`deploy/nginx.example.conf` shows a static `location` and, commented out, a reverse proxy to the built-in port. Give the publish directory to the user that runs the service:

```bash
sudo mkdir -p /var/www/html/greyline
sudo chown "$USER" /var/www/html/greyline
```

`data/status.json` changes every few seconds. The nginx example sends `Cache-Control: no-store` for that directory. `publish.status_interval_sec` (minimum 5, default 15) is how often the file is replaced. Raise it if you want fewer writes on a Pi SD card. The clock and the greyline keep moving between writes.

## Pages

Pages are the part you actually set up. Each one is a stable URL. A screensaver is told that URL and nothing else.

```json
"pages": [
  {
    "id": "main",
    "title": "Shack",
    "slug": "",
    "panels": ["clock", "map", "space_weather", "bands", "dx_spots"],
    "dx_rows": 10,
    "show_vhf": true,
    "map": { "spots": true, "labels": true, "greyline": true, "home": true, "sun": true },
    "burn_in": { "enabled": true, "period_sec": 180, "pixels": 8 }
  },
  {
    "id": "map",
    "title": "Map",
    "slug": "map",
    "panels": ["clock", "map", "dx_spots"],
    "dx_rows": 8
  }
]
```

`slug` is the path. An empty slug is the root of the site. Panels are `clock`, `map`, `space_weather`, `bands`, and `dx_spots`. Unknown names are rejected at startup.

`clients` is a note to yourself, shown on `/pages/`:

```json
"clients": [
  { "name": "shack-display", "page": "main" },
  { "name": "laptop", "page": "map" }
]
```

Save `config.json` and the running process picks up page changes without a restart. Host, port, and the publish directory still need a restart. Open screens pick up panel changes on the next refresh (about 20 seconds).

The whole window drifts a few pixels on `burn_in.period_sec` so a fixed dashboard does not sit on the same pixels all day. Text is off-white on near-black rather than pure white.

## Station

```json
"station": {
  "callsign": "K0JNM",
  "grid": "EL87uu",
  "timezone": "America/New_York"
}
```

A grid square is enough. `latitude` and `longitude` (longitude positive east) override it when both are set. The header shows UTC and this timezone, sunrise and sunset, and whether the station is in day, night, or on the greyline (solar elevation between −12° and +6°).

## Where to leave it running

On a Raspberry Pi or other always-on Linux host, `deploy/greyline-hub.service` is a systemd unit. Point `WorkingDirectory` and `ExecStart` at the checkout. It restarts if the process dies.

On a Mac that stays at home, `clients/macos/install-local-server.sh` installs a LaunchAgent that does the same job.

A laptop does not have to be the home server. Its screensaver tries the home URL, then localhost. See below.

## What a screensaver does

The client contract is in `clients/README.md`. Short version:

1. Request the primary URL (the home page you chose). Wait about 1.5 seconds.
2. If it does not answer, request the secondary URL, usually `http://127.0.0.1:8754/` or a page under it.
3. If that is down too, start `python3 greyline-hub --port 8754` in the checkout and poll until it answers.
4. Show the page full screen. If nothing answered, show the URLs that were tried.

An HTTP status from 200 to 399 counts as up, whether the page comes from the built-in server or from a folder on nginx.

The macOS saver is `clients/macos/`. A fresh install opens the shack page at `/` (space weather, HF bands, map, and spots). Build it on a Mac with `./build.sh`. This repository was prepared on Linux, so the `.saver` bundle was not compiled here. Rebuild steps, the blank-screen workaround for macOS 26 and 27, and how to collect logs are in `clients/macos/README.md`.

## Data

Feeds are fetched by the one Python process and cached in `var/cache.json`. A failed fetch keeps the last good payload. Panels show that stale data, with the age, instead of going blank. The map, the clock, and the greyline are computed locally and still draw when every feed is down.

| What | Source | Cadence |
| --- | --- | --- |
| 10.7 cm solar flux (SFI) | [NOAA SWPC](https://services.swpc.noaa.gov/products/summary/10cm-flux.json) | 5 min |
| Planetary Kp and the running ap | [NOAA SWPC K index](https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json) | 5 min |
| X-ray class (GOES 0.1–0.8 nm) | [NOAA SWPC](https://services.swpc.noaa.gov/json/goes/primary/xrays-6-hour.json) | 5 min |
| Solar-wind speed and Bz | [NOAA SWPC summaries](https://services.swpc.noaa.gov/products/summary/solar-wind-speed.json) | 5 min |
| R/S/G scales | [NOAA SWPC scales](https://services.swpc.noaa.gov/products/noaa-scales.json) | 5 min |
| Daily sunspot number | [SIDC EISN](https://www.sidc.be/SILSO/DATA/EISN/EISN_current.txt) | 5 min |
| Daily A index, HF band conditions, VHF notes | [N0NBH](https://www.hamqsl.com/solarxml.php) `solarxml.php` | 10 min |
| DX spots (call, frequency, spotter, comment, coordinates) | [DX Summit](https://www.dxsummit.fi/api/v1/spots) | 1 min |

N0NBH is polled slowly on purpose. If it is down and SFI or Kp is known, the band panel shows a coarse estimate labeled as an estimate. That estimate is a desk rule (high flux favors the high bands, a high K index degrades every band). It is not a path forecast from your station to a DX station.

DX Summit longitudes are positive west, the same convention as the country file. The map uses positive east. Spot positions are the coordinates DX Summit publishes, often a state or country centroid, not a rooftop.

An optional telnet cluster (`feeds.telnet_enabled`) logs in with your callsign and parses `DX de` lines. Leave it off unless you want one cluster in addition to DX Summit. Spots from telnet have no coordinates, so they are placed with the country file.

The country file is `greyline_hub/data/cty.dat` (Jim Reisert, AD1C, [country-files.com](https://www.country-files.com/cty/cty.dat)). The coastline is Natural Earth 1:110m land, public domain, rounded for this map. Provenance is in `greyline_hub/data/SOURCES.txt`. Replace `cty.dat` to update prefixes.

`python3 greyline-hub --check` fetches every feed once and prints the numbers. Exit status is 1 only when space weather and the spot list are both empty.

## Config file

`GREYLINE_CONFIG` or `--config` selects a file. Otherwise Greyline Hub uses `./config.json`, then `config.json` next to the checkout, then `config.example.json` (with a warning). `//` and `/* */` comments are allowed.

`runtime_dir` is where `cache.json` and the generated site live. The default is `var/` inside the checkout.

## Tests

```bash
python3 -m unittest discover -s tests
```

## Roadmap

- **Windows.** A small WebView2 `.scr` that follows `clients/README.md`: probe primary, probe secondary, start `python greyline-hub --port …` if needed, show the URL.
- **Ubuntu.** The same ladder in a WebKitGTK saver or an XScreenSaver helper that launches a fullscreen browser. A machine that already runs a browser kiosk can open the page URL with no new client at all.
- Path-specific propagation (a forecast from your grid to a DX station, rather than the global N0NBH band table).
- A direct cluster as a first-class spot source, once a callsign is configured for the login.

## Layout of the repo

```
greyline-hub                 launcher
greyline_hub/                Python package, dashboard assets, cty.dat, coastline
config.example.json
clients/macos/               Swift saver, build.sh, LaunchAgent installer
deploy/                      systemd unit and nginx example
tests/
```
