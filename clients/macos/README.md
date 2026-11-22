# Greyline Hub for macOS

This is a native screen saver (`GreylineHub.saver`). It is a `ScreenSaverView`
with a `WKWebView`. The view tries the home-server page, then a page on
localhost, and can start the local Python server if localhost is down.

The Python server and the dashboard were exercised on Linux. This saver was
**not compiled or installed here**, because that requires macOS. Build it on
a Mac with the script below.

## Build

Install Xcode or the Command Line Tools, then:

```bash
cd clients/macos
./build.sh
cp -R build/GreylineHub.saver ~/Library/Screen\ Savers/
```

Open System Settings → Screen Saver and choose Greyline Hub. If macOS blocks
the unsigned bundle:

```bash
xattr -dr com.apple.quarantine ~/Library/Screen\ Savers/GreylineHub.saver
```

`build.sh` compiles `Sources/GreylineHubView.swift` with `swiftc` for the
Mac's architecture (and a second architecture when the SDK allows it),
writes the bundle layout, and ad-hoc signs it. You can also drop the same
source into an Xcode "Screen Saver" target. The principal class is
`GreylineHubView`. The deployment target is macOS 12.

## What the saver opens

In the screensaver options, set:

- **Primary URL.** The page on the home server. Examples:
  `http://radio.home/greyline/` or `http://192.168.1.20:8754/map/`.
  Use the path of the page you want on that screen.
- **Secondary URL.** Usually `http://127.0.0.1:8754/` or
  `http://127.0.0.1:8754/map/`. The port has to match the local server.
- **Folder.** The Greyline Hub checkout, used only when the secondary URL
  does not answer and the saver is allowed to start Python.
- **Port.** Passed as `--port` when the saver starts Python.

The same fields live in
`~/Library/Application Support/GreylineHub/client.json`. A template is
`Support/client.example.json`. On a sandboxed saver this directory may be
inside the saver's container. The saver logs the path it wrote
(`Greyline Hub wrote …`) in Console.

The primary probe waits `connect_timeout_sec` (default 1.5). Any HTTP status
from 200 to 399 counts as up, so a static folder on nginx works the same as
the built-in server.

## Keep localhost running

macOS Sonoma and later load legacy savers inside a sandbox. The sandbox often
refuses to spawn Python or to read a folder outside the container. The saver
still tries, and if it cannot, it says so instead of going blank.

The dependable setup is a LaunchAgent that starts the server at login:

```bash
cd clients/macos
./install-local-server.sh ~/greyline-hub 8754
```

Then set the secondary URL to `http://127.0.0.1:8754/` (or a page under it)
and you can turn off "Start the local Python server" in the options. The
agent restarts the server if it exits. Logs go to
`~/Library/Logs/GreylineHub.log`.

`Info.plist` allows plain HTTP (`NSAllowsArbitraryLoads` and
`NSAllowsLocalNetworking`) because a home dashboard is often
`http://` on the LAN. The URL is one you configured, not one the saver discovers.
