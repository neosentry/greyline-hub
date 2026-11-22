# Screensaver clients

A client does not collect space weather or draw the map. It opens one page URL
that Greyline Hub already published. The page (which panels, how many spots,
the station, the greyline) comes from `config.json` on the server.

## What every client does

1. Read its own small config: a primary URL, a secondary URL, a timeout, and
   how to start a local copy of the server.
2. Request the primary URL. Anything that answers `200`–`399` within about
   1.5 seconds is up. This works for the built-in server and for a folder
   served by nginx, Caddy, or Apache, because both are ordinary web pages.
3. If the primary does not answer, request the secondary URL (usually
   `http://127.0.0.1:<port>/` or a specific page such as `/map/`).
4. If the secondary is also down, start the local server and poll the
   secondary URL until it answers or the start timeout passes.
   The command is `python3 greyline-hub --port <port>` with the working
   directory set to the checkout. Skip this step when a LaunchAgent or
   systemd unit already keeps the local server running.
5. Show that URL full screen. If nothing answered, show a short message
   with the URLs that were tried. Do not show a blank screen.
6. Leave the page open. The page itself keeps polling `data/status.json`.

The URL is the whole configuration a screen needs. `http://home.lan/greyline/`
and `http://home.lan/greyline/map/` are different pages. Add or edit pages in
the server config; clients do not get a new build.

## Files

| Path | Role |
| --- | --- |
| `macos/` | Swift screen saver, build script, LaunchAgent installer |
| later `windows/` | A small WebView2 `.scr` that follows the steps above |
| later `ubuntu/` | A WebKitGTK or kiosk-browser saver that follows the steps above |

macOS build and install steps are in `macos/README.md`.
