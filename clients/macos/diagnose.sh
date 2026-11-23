#!/bin/bash
# Print how the installed Greyline Hub saver is built and signed.
# Usage: ./diagnose.sh [path/to/GreylineHub.saver]
# Paste the whole output if the screen stays blank and no log file appears.

set -u
SAVER="${1:-${HOME}/Library/Screen Savers/GreylineHub.saver}"
BIN="${SAVER}/Contents/MacOS/GreylineHub"
PLIST="${SAVER}/Contents/Info.plist"

section() {
  printf '\n===== %s =====\n' "$1"
}

section "path"
printf '%s\n' "$SAVER"
if [ ! -d "$SAVER" ]; then
  echo "saver bundle not found"
  echo "usage: $0 [path/to/GreylineHub.saver]"
  exit 1
fi

section "Info.plist"
if [ -f "$PLIST" ]; then
  # plutil prints the principal class, version, and minimum OS.
  plutil -p "$PLIST" 2>/dev/null || cat "$PLIST"
else
  echo "missing $PLIST"
fi

section "binary"
if [ ! -f "$BIN" ]; then
  echo "missing $BIN"
else
  file "$BIN" 2>/dev/null || true
  echo "-- lipo -archs --"
  lipo -archs "$BIN" 2>&1 || true
  echo "-- uname -m --"
  uname -m
  echo "-- otool -L (linked libraries) --"
  otool -L "$BIN" 2>&1 || true
  echo "-- LC_RPATH --"
  otool -l "$BIN" 2>/dev/null | awk '/LC_RPATH/{p=1} p && /path /{print; p=0}' || true
  echo "-- GreylineHubView symbol --"
  nm -gU "$BIN" 2>/dev/null | grep GreylineHub || echo "no GreylineHub symbol exported"
fi

section "codesign -dv --verbose=4 (bundle)"
codesign -dv --verbose=4 "$SAVER" 2>&1 || true

section "codesign --verify (bundle)"
codesign --verify --verbose=4 "$SAVER" 2>&1 || true

section "codesign --verify (binary)"
if [ -f "$BIN" ]; then
  codesign --verify --verbose=4 "$BIN" 2>&1 || true
fi

section "host"
sw_vers 2>/dev/null || true
echo "If lipo does not list the same architecture as uname -m, the saver cannot load."
echo "If otool shows @rpath/libswift*.dylib and that path is not on the saver, dyld fails before any log line."
echo "A constructor log in /tmp/GreylineHub-saver.log means the binary did load."
