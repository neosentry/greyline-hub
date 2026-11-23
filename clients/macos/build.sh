#!/bin/bash
# Build GreylineHub.saver on macOS. This script does not run on Linux.
# Requires Xcode or the Command Line Tools (swiftc, xcrun, codesign, lipo).

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
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
rm -rf build
mkdir -p "$ROOT/MacOS" "$ROOT/Frameworks" "$ROOT/Resources" "$TMP"

# legacyScreenSaver loads this bundle inside its own process. Swift libraries
# recorded as @rpath are not found there, dyld rejects the bundle, and none of
# our code runs. Point those dependencies at the OS copies, and embed any
# compatibility library that exists only in the toolchain.
relink_swift() {
  local bin="$1"
  local dep base dest
  while IFS= read -r dep; do
    case "$dep" in
      @rpath/libswift*|@rpath/libswiftCompatibility*)
        base="$(basename "$dep")"
        if [ -f "/usr/lib/swift/${base}" ]; then
          install_name_tool -change "$dep" "/usr/lib/swift/${base}" "$bin"
        elif [ -f "${TOOLCHAIN}/${base}" ]; then
          dest="$ROOT/Frameworks/${base}"
          cp -f "${TOOLCHAIN}/${base}" "$dest"
          chmod 755 "$dest"
          install_name_tool -change "$dep" "@loader_path/../Frameworks/${base}" "$bin"
        else
          echo "warning: cannot resolve ${dep}" >&2
        fi
        ;;
    esac
  done < <(otool -L "$bin" | awk 'NR > 1 { print $1 }')
}

build_arch() {
  local arch="$1"
  local obj="$TMP/load-${arch}.o"
  xcrun clang -c Sources/GreylineHubLoad.m \
    -target "${arch}-apple-macosx${MIN}" \
    -isysroot "$SDK" \
    -fobjc-arc \
    -O2 \
    -o "$obj"
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
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
    -o "$TMP/GreylineHub-${arch}" \
    Sources/GreylineHubView.swift \
    "$obj"
  relink_swift "$TMP/GreylineHub-${arch}"
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
chmod 755 "$ROOT/MacOS/GreylineHub"

# Sign the inner binaries first, then the bundle. --deep alone often leaves
# the Mach-O unsigned, and macOS 26/27 then refuses to map the saver.
if command -v codesign >/dev/null 2>&1; then
  while IFS= read -r lib; do
    codesign --force --sign - --timestamp=none "$lib"
  done < <(find "$ROOT/Frameworks" -type f 2>/dev/null || true)
  codesign --force --sign - --timestamp=none "$ROOT/MacOS/GreylineHub"
  codesign --force --sign - --timestamp=none "build/GreylineHub.saver"
  codesign --verify --verbose=2 "build/GreylineHub.saver"
fi

echo
echo "Built build/GreylineHub.saver (${BUILT[*]})"
file "$ROOT/MacOS/GreylineHub" || true
echo "-- lipo -archs --"
lipo -archs "$ROOT/MacOS/GreylineHub" || true
echo "-- otool -L --"
otool -L "$ROOT/MacOS/GreylineHub" || true
echo "Install:"
echo "  killall legacyScreenSaver 2>/dev/null || true"
echo "  rm -rf ~/Library/Screen\\ Savers/GreylineHub.saver"
echo "  cp -R build/GreylineHub.saver ~/Library/Screen\\ Savers/"
echo "  xattr -dr com.apple.quarantine ~/Library/Screen\\ Savers/GreylineHub.saver"
echo "Then run ./diagnose.sh and send the output if the screen stays blank."
