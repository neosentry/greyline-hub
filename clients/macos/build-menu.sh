#!/bin/bash
# Build the Greyline Hub menu-bar app and install it to ~/Applications.
# Command Line Tools are enough. There is no Xcode project.

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcrun >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc and xcrun are required. Install Xcode or the Command Line Tools." >&2
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN="14.0"
APP="build/Greyline Hub.app"
MACOS="$APP/Contents/MacOS"
TMP="build/menu"
rm -rf "$APP" "$TMP"
mkdir -p "$MACOS" "$TMP"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>GreylineHubMenu</string>
  <key>CFBundleIdentifier</key>
  <string>com.greylinehub.menu</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Greyline Hub</string>
  <key>CFBundleDisplayName</key>
  <string>Greyline Hub</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.8</string>
  <key>CFBundleVersion</key>
  <string>9</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

build_arch() {
  local arch="$1"
  local out="$TMP/GreylineHubMenu-${arch}"
  swiftc \
    -sdk "$SDK" \
    -target "${arch}-apple-macosx${MIN}" \
    -framework Cocoa \
    -O \
    -o "$out" \
    Sources/GreylineHubMenu.swift
}

echo "build-menu.sh: compiling arm64"
build_arch arm64
BUILT=(arm64)
echo "build-menu.sh: compiling optional x86_64"
if build_arch x86_64; then
  BUILT+=(x86_64)
else
  echo "build-menu.sh: x86_64 slice did not build. Continuing with arm64 only." >&2
fi

if [ "${#BUILT[@]}" -eq 1 ]; then
  cp "$TMP/GreylineHubMenu-arm64" "$MACOS/GreylineHubMenu"
else
  lipo -create "$TMP/GreylineHubMenu-arm64" "$TMP/GreylineHubMenu-x86_64" -output "$MACOS/GreylineHubMenu"
fi
chmod 755 "$MACOS/GreylineHubMenu"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$MACOS/GreylineHubMenu"
  codesign --force --sign - --timestamp=none "$APP"
  codesign --verify --verbose=2 "$APP"
fi

DEST="${HOME}/Applications/Greyline Hub.app"
mkdir -p "${HOME}/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "Installed ${DEST}"
echo "Open it from Finder, or run: open \"${DEST}\""
echo "The menu title is GL. Configuration is http://127.0.0.1:8754/config/ unless config.json uses another port."
