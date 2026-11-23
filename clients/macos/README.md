# Greyline Hub for macOS

A `ScreenSaverView` that draws the shack dashboard itself: map, greyline,
clocks, space weather, HF bands, and DX spots. It reads
`~/Library/Screen Savers/GreylineHub-site/data/status.json`, which the Python
server publishes. It does not open a web view unless Screen Saver options
turn WebKit on.

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
The native saver uses the URL only to choose the shack page or `/map/`. The
picture is drawn from `GreylineHub-site/data/status.json`, not from WebKit.

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
./diagnose.sh
```

`./build.sh` looks for `/Library/Screen Savers/GreylineHub.saver`. WallpaperAgent
loads that system-wide bundle before the copy in your home folder. An old
root-owned 0.1.0 there is what ran while newer builds sat unused in
`~/Library/Screen Savers`. When that directory exists, the script prints:

```bash
sudo rm -rf /Library/Screen\ Savers/GreylineHub.saver
```

Run that, then install the home-folder copy again. `./diagnose.sh` prints the
version of both locations, plus the principal class, architectures, linked
Swift libraries, the code signature, and the last few minutes of unified-log
lines for `com.greylinehub.screensaver`. Paste that output if the screen stays
blank.

Open System Settings → Wallpaper → Screen Saver (on macOS 26 and 27 the
screen saver list lives inside Wallpaper) and choose Greyline Hub. This build
is version 0.1.8 (bundle version 9). The footer on screen says `Greyline Hub 0.1.8 (9) · native`. `./build.sh` needs Xcode or the Command
Line Tools. The deployment target is macOS 14, so the same binary runs on
Sonoma and later.

Screen Saver options are only the WebKit checkbox, plus a note. Station,
panels, presets, filters, the port, and publish folders are edited at
`http://127.0.0.1:8754/config/` (use the port in `config.json` if you changed
it). Options often will not reopen until System Settings is quit. That is a
macOS 26 bug in the screen saver UI.

## Menu-bar app

`build-menu.sh` compiles a small status-item app with the Command Line Tools
and copies it to `~/Applications/Greyline Hub.app`. It shows whether the
server is answering, opens the configuration page, starts, stops, or restarts
the `com.greylinehub.server` LaunchAgent, and opens the log.

```bash
cd clients/macos
./build-menu.sh
open "$HOME/Applications/Greyline Hub.app"
```

The menu title is **GL**. Reinstall the LaunchAgent after this update so it
stops forcing `--port` and `--publish`. The server then follows `config.json`,
and on macOS it still publishes the saver copy to
`~/Library/Screen Savers/GreylineHub-site`. Homebrew Python is preferred
(`/opt/homebrew/bin/python3`, including 3.14):

```bash
./install-local-server.sh /path/to/greyline-hub
```

## If the screen goes black

0.1.6 still went blank. The host log showed `hideContentUntilPendingUpdate`
on the WebKit layer tree, and none of the saver's own log lines were present.
0.1.7 does not create a `WKWebView` on the normal path. `draw` paints the
dashboard with Core Graphics, including a greyline computed in the saver from
the current time. The published JSON supplies the station, space weather
(SFI, SSN, Kp, A, X-ray, wind, Bz, NOAA scales), band table, and DX spots.
If that file is missing, the clocks, the Florida station, and the greyline
still draw, and the footer says the site was not found.

The footer should read `Greyline Hub 0.1.8 (9) · native`. If it does not, the
running host is still an older bundle. Check `/Library/Screen Savers` as well
as your home folder: macOS loads the system-wide saver first. `legacyScreenSaver`
keeps the previous binary mapped until that process exits. Quit System Settings
and kill `legacyScreenSaver` before copying the new bundle.

Logs use `os_log` with subsystem `com.greylinehub.screensaver` and a public
`%{public}@` string that begins with `greyline`. `./diagnose.sh` prints the
recent ones. A live stream:

```bash
log stream --predicate 'subsystem == "com.greylinehub.screensaver" OR eventMessage CONTAINS "greyline"' --level debug
```

The file is written under the screen saver container, which `NSHomeDirectory()`
returns inside the sandbox:

```bash
ls -l ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/GreylineHub-saver.log
```

WebKit remains available only if Screen Saver options check "Use WebKit",
or `client.json` sets `"renderer": "webkit"`. Leave that off. The sandbox also
blocks HTTP, including `127.0.0.1`. Both probes timing out
at the same budget with zero bytes sent is that restriction, not a slow
server. The saver reads the shack page from
`~/Library/Screen Savers/GreylineHub-site`. That directory sits next to the
`.saver` bundles, which the screen-saver sandbox is allowed to read, and it
is not inside another app's container, so the unsandboxed Python process is
allowed to write it. Writing into
`~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver` is
blocked by macOS (TCC) and is not required. If a future OS stops the saver
from reading `~/Library/Screen Savers`, grant Full Disk Access to the
`python3` that runs Greyline Hub and set `--publish` to the container path.
That is a fallback, not the default. Restart the server after you pull, or
reinstall the LaunchAgent with the path of your clone.

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
cd /path/to/your/greyline-hub/clients/macos
./install-local-server.sh /path/to/your/greyline-hub 8754
```

Pass the directory you actually cloned. It is the folder that contains the
`greyline-hub` launcher, not a fixed path under your home directory. The
agent also publishes the shack page into the screen saver container, which
is the copy the saver can read when the sandbox blocks `127.0.0.1`.

Run that in Terminal.app on the Mac. Over SSH, `launchctl bootstrap gui/…`
fails with `Bootstrap failed: 125: Domain does not support specified action`
because that domain only exists in a graphical login. The script detects that,
leaves the plist in `~/Library/LaunchAgents`, and tells you to rerun it on the
console. It also waits for `bootout` to finish, retries bootstrap, and falls
back to `launchctl load -w`. It prints success only after
`http://127.0.0.1:8754/api/health` answers.

```bash
./uninstall-local-server.sh
```

Point the secondary URL at `http://127.0.0.1:8754/` (the shack page) and you
can turn off "Start the local Python server". The agent log is
`~/Library/Logs/GreylineHub.log`.

`Info.plist` allows plain `http://` loads. The host process may still apply
its own network policy; a failure of that kind is written to the saver log
and shown on screen.
