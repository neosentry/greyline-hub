#!/bin/bash
# Build GreylineHub.saver on macOS. This script does not run on Linux.
# Requires Xcode or the Command Line Tools (swiftc, xcrun, codesign).

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcrun >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc and xcrun are required. Install Xcode or the Command Line Tools." >&2
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN="14.0"
ROOT="build/GreylineHub.saver/Contents"
TMP="build/objs"
rm -rf build
mkdir -p "$ROOT/MacOS" "$ROOT/Resources" "$TMP"

build_arch() {
  local arch="$1"
  swiftc \
    -sdk "$SDK" \
    -target "${arch}-apple-macosx${MIN}" \
    -framework Cocoa \
    -framework ScreenSaver \
    -framework WebKit \
    -emit-library \
    -module-name GreylineHub \
    -O \
    -Xlinker -bundle \
    -o "$TMP/GreylineHub-${arch}" \
    Sources/GreylineHubView.swift
}

HOST="$(uname -m)"
BUILT=()
for arch in "$HOST" arm64 x86_64; do
  case " ${BUILT[*]-} " in
    *" $arch "*) continue ;;
  esac
  if build_arch "$arch"; then
    BUILT+=("$arch")
  else
    echo "skipping $arch" >&2
  fi
done

if [ "${#BUILT[@]}" -eq 0 ]; then
  echo "swiftc produced no binary" >&2
  exit 1
fi
if [ "${#BUILT[@]}" -eq 1 ]; then
  cp "$TMP/GreylineHub-${BUILT[0]}" "$ROOT/MacOS/GreylineHub"
else
  lipo -create "${BUILT[@]/#/$TMP/GreylineHub-}" -output "$ROOT/MacOS/GreylineHub"
fi

cp Support/Info.plist "$ROOT/Info.plist"
cp Support/client.example.json "$ROOT/Resources/client.example.json"
chmod +x "$ROOT/MacOS/GreylineHub"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --deep build/GreylineHub.saver || true
fi

echo
echo "Built build/GreylineHub.saver (${BUILT[*]})"
echo "Install:  cp -R build/GreylineHub.saver ~/Library/Screen\\ Savers/"
echo "Then open System Settings → Screen Saver and choose Greyline Hub."
echo "If macOS refuses an unsigned saver:"
echo "  xattr -dr com.apple.quarantine ~/Library/Screen\\ Savers/GreylineHub.saver"
