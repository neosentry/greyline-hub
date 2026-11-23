# Greyline Hub on Ubuntu

Written for **Ubuntu 26.04 LTS** with **GNOME on Wayland** (Mutter). X11 and
XScreenSaver still work, as a second path. The same Python server and
`http://127.0.0.1:8754/config/` page are used. There is nothing to pip install.
Python 3.9 or newer is required; 26.04's `python3` is well past that.

GNOME has no screen-saver module slot. An idle service asks Mutter how long
the seat has been idle. After the configured minutes it opens a fullscreen
GTK 4 / WebKitGTK 6 window on the dashboard. Input closes that window. GNOME's
own Blank Screen must be **longer** than that idle time, or turned off, or the
black blank covers the dashboard.

## 1. Clone

On `jm-sys76`, as `jmartin`:

```bash
mkdir -p "$HOME/radiodash"
cd "$HOME/radiodash"
git clone https://github.com/neosentry/greyline-hub.git
cd greyline-hub
```

If the Linux client is still on a pull request branch, check that branch out
before the install scripts. After it is merged, `main` is enough.

## 2. Packages

The saver install runs `apt-get` for you. These are the packages:

| Package | Why |
| --- | --- |
| `python3` | Server and idle watcher. Standard library only. |
| `python3-gi`, `gir1.2-gtk-4.0`, `gir1.2-webkit-6.0` | Fullscreen dashboard on Wayland. |
| `libglib2.0-bin` | `gdbus`, used to call Mutter IdleMonitor. |
| `xdg-utils` | Opens the config page from the launcher. |
| `gir1.2-ayatanaappindicator3-0.1`, `gnome-shell-extension-appindicator` | Optional tray icon. Ubuntu's AppIndicator extension is usually already installed. |
| `xprintidle` | Optional. Used only on X11 when Mutter is not available. |
| `xscreensaver` | Optional. Only if you run XScreenSaver instead of the idle service. |

A browser (`firefox` or `chromium`) is the fallback if WebKitGTK 6 is missing.

## 3. Server service

Run this in a terminal **inside the GNOME session** (a local Terminal window,
not an SSH session that has no user systemd):

```bash
cd "$HOME/radiodash/greyline-hub"
clients/linux/install-server.sh
```

That writes `~/.config/systemd/user/greyline-hub.service`, enables it, and
starts it. It copies `config.example.json` to `config.json` when you do not
already have one. The station in the example is K0JNM / EL87uu.

Open `http://127.0.0.1:8754/config/` and set the callsign, grid, port, panels,
and the Linux idle minutes. Saving stays on localhost unless you turn on LAN
writes. A port change needs:

```bash
systemctl --user restart greyline-hub.service
```

Logs:

```bash
journalctl --user -u greyline-hub.service -f
```

Remove it with `clients/linux/uninstall-server.sh`. `config.json` is left in
the clone.

## 4. Idle screen

```bash
clients/linux/install-saver.sh
```

This installs the WebKit packages, `~/.config/systemd/user/greyline-hub-idle.service`,
a Greyline Hub application launcher, and an autostart entry. The autostart
entry only shows a tray icon when the Ayatana typelib is present. Without it,
open **Greyline Hub** from the app grid. That window can open the config page,
start and stop the services, and run the saver immediately.

Turn GNOME's blank off, or make it later than the idle time (the default idle
time is 5 minutes, so 15 minutes is a safe blank, and 0 means off):

```bash
gsettings get org.gnome.desktop.session idle-delay
gsettings set org.gnome.desktop.session idle-delay 0
```

Settings → Power → Blank Screen is the same value. Screen lock, if you want
it, should also wait until after the dashboard has had time to appear
(`org.gnome.desktop.screensaver lock-delay`).

The idle service is part of the graphical session, so it stops at logout and
does not run on the login screen. It reads `linux` in `config.json`:

```json
"linux": {
  "idle_minutes": 5,
  "display": "",
  "renderer": "auto",
  "page": "/"
}
```

`display` stays empty on Wayland. Set it to `:1` only for a specific X11
screen. `renderer` `auto` uses WebKitGTK 6, then WebKit2 if that is all that
is installed, then Chromium, then Firefox. `page` `/map/` is the map without
the space-weather column.

Restart the idle service after a change if it does not pick it up within a
few seconds (it re-reads the file each poll):

```bash
systemctl --user restart greyline-hub-idle.service
```

Show the dashboard once, without waiting:

```bash
python3 greyline-hub kiosk --exit-on-input
```

A key or a click closes it.

If the window is black but the process is running, WebKit's Wayland GPU path
is the usual cause. Stop the kiosk and try:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 python3 greyline-hub kiosk --exit-on-input
```

## 5. X11 and XScreenSaver

On an Xorg session the idle service tries `xprintidle` first, then Mutter if
this is still GNOME. Install `xprintidle` (the saver script does, when apt
can see it).

XScreenSaver does not use the idle service. The install script copies
`~/.local/bin/greyline-hub-xscreensaver` and, when `~/.xscreensaver` already
has a `programs:` list, adds:

```
greyline-hub-xscreensaver --root \n\
```

Run `xscreensaver-demo` once if that file does not exist yet, re-run
`install-saver.sh`, and choose Greyline Hub. XScreenSaver starts that program
and kills it when there is input. The program opens its own fullscreen
window. It does not draw inside the small XScreenSaver preview.

Do not run the idle service and XScreenSaver at the same time.

## 6. Diagnose

```bash
clients/linux/diagnose.sh
```

It prints the session type, whether Mutter or xprintidle answers, the
WebKit/browser renderers Python can see, the GNOME blank delay, and both
user services. Paste that output if the screen never appears.

## What the services are

| Unit | Role |
| --- | --- |
| `greyline-hub.service` | Python server. Starts at login, including without a display. |
| `greyline-hub-idle.service` | After N minutes idle, fullscreen dashboard. Stops at logout. |
