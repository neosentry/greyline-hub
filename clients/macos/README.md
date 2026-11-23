# Greyline Hub for macOS

A `ScreenSaverView` with a `WKWebView`. It tries the home server, then a page
on this Mac, and can start the local Python server if localhost is down.

The Python server was exercised on Linux. The `.saver` itself has to be built
on a Mac. It is written for the legacy screen saver host used by macOS 14
through macOS 27, including 27.2.1.

## Which page it opens

A fresh install opens the **shack page**, the site root:

- Primary: `http://greyline.local:8754/`
- Secondary: `http://127.0.0.1:8754/`

That page is the clock, the greyline map, space weather (SFI, SSN, Kp, A,
X-ray, solar wind, Bz, NOAA R/S/G), HF band conditions, and DX spots. On a
full screen the space-weather figures are drawn larger than in a small window.

To change the page, edit the URL in Screen Saver options, or in
`~/Library/Application Support/GreylineHub/client.json` (the sandbox may put
that file under `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/`).
A URL that ends in `/map/` is the map without space weather. Anything else is
whatever page you published at that path. `//` comments are allowed in the JSON.

## Build and reinstall

Quit System Settings first. The old saver stays mapped in `legacyScreenSaver`
until that process is gone.

```bash
cd clients/macos
./build.sh
killall legacyScreenSaver 2>/dev/null || true
killall ScreenSaverEngine 2>/dev/null || true
rm -rf ~/Library/Screen\ Savers/GreylineHub.saver
cp -R build/GreylineHub.saver ~/Library/Screen\ Savers/
xattr -dr com.apple.quarantine ~/Library/Screen\ Savers/GreylineHub.saver
```

Open System Settings → Wallpaper → Screen Saver (on macOS 26 and 27 the
screen saver list lives inside Wallpaper) and choose Greyline Hub. This build
is version 0.1.1 (bundle version 2). `./build.sh` needs Xcode or the Command
Line Tools. The deployment target is macOS 14, so the same binary runs on
Sonoma and later.

If the Options button does nothing, quit System Settings and open it again.
That is a macOS 26 bug in the screen saver UI, not in this bundle.

## If the screen goes black

On macOS 26.4 and later, `legacyScreenSaver` treats a web view as a hidden
background view. The dashboard paints, then WebKit suspends it and the
display goes black. This build asks WebKit to leave the view active, drives
the clock from the saver's own timer, and keeps a native status line on top
of the web view. The status line is AppKit text, so it stays readable when
the web view is empty. It says what it is trying:

```
Greyline Hub
Trying home server http://greyline.local:8754/
Shack page: space weather, HF bands, map, and spots.
Home server did not answer: The request timed out.
Trying this Mac http://127.0.0.1:8754/
```

A failure stays on that screen with the reason. It does not go back to an
empty black frame.

The same lines are appended to a log file. The on-screen text includes the
path. These are the places to look, because the sandbox may redirect `~/Library`:

```bash
ls -l ~/Library/Logs/GreylineHub-saver.log \
  ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/GreylineHub-saver.log \
  /tmp/GreylineHub-saver.log
```

Live messages, including ones that never made it into the file:

```bash
log stream --predicate 'subsystem == "com.greylinehub.screensaver"' --level info
```

Leave that running, start the screen saver, wait until it fails, then stop
the stream. Send the log file plus that output.

Safari's Develop menu can inspect the page while the System Settings preview
is open (`WKWebView.isInspectable` is on). After a rebuild, kill
`legacyScreenSaver` again or the old bundle keeps running.

## Keep localhost running

The screen saver sandbox often refuses to launch Python. A LaunchAgent is the
reliable way to keep the local server up:

```bash
cd clients/macos
./install-local-server.sh ~/greyline-hub 8754
```

Point the secondary URL at `http://127.0.0.1:8754/` (the shack page) and you
can turn off "Start the local Python server". The agent log is
`~/Library/Logs/GreylineHub.log`.

`Info.plist` allows plain `http://` loads. The host process may still apply
its own network policy; a failure of that kind is written to the saver log
and shown on screen.
