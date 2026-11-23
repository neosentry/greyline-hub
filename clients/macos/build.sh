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
          if ! install_name_tool -change "$dep" "/usr/lib/swift/${base}" "$bin"; then
            echo "build.sh: install_name_tool failed for ${dep}" >&2
            return 1
          fi
        elif [ -f "${TOOLCHAIN}/${base}" ]; then
          dest="$ROOT/Frameworks/${base}"
          cp -f "${TOOLCHAIN}/${base}" "$dest"
          chmod 755 "$dest"
          if ! install_name_tool -change "$dep" "@loader_path/../Frameworks/${base}" "$bin"; then
            echo "build.sh: install_name_tool failed for ${dep}" >&2
            return 1
          fi
        else
          echo "build.sh: cannot resolve ${dep}" >&2
          return 1
        fi
        ;;
    esac
  done < <(otool -L "$bin" | awk 'NR > 1 { print $1 }')
}

# Print the command, then run it. Return its status. Do not rely on set -e:
# macOS /bin/bash 3.2 ignores set -e for an entire function called from if.
run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

build_arch() {
  local arch="$1"
  local obj="$TMP/load-${arch}.o"
  local out="$TMP/GreylineHub-${arch}"
  if ! run_cmd xcrun clang -c Sources/GreylineHubLoad.m \
    -target "${arch}-apple-macosx${MIN}" \
    -isysroot "$SDK" \
    -fobjc-arc \
    -O2 \
    -o "$obj"
  then
    echo "build.sh: clang failed for ${arch}. Stop this slice." >&2
    return 1
  fi
  if ! run_cmd swiftc \
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
    -o "$out" \
    Sources/GreylineHubNative.swift \
    Sources/GreylineHubView.swift \
    "$obj"
  then
    echo "build.sh: swiftc failed for ${arch}. Stop this slice." >&2
    return 1
  fi
  if [ ! -f "$out" ]; then
    echo "build.sh: swiftc exited 0 but did not write ${out}" >&2
    return 1
  fi
  if ! relink_swift "$out"; then
    echo "build.sh: could not retarget Swift libraries in ${out}" >&2
    return 1
  fi
}

echo "build.sh: compiling required arm64 slice"
if ! build_arch arm64; then
  echo "build.sh: arm64 build failed. Not running lipo." >&2
  exit 1
fi
BUILT=(arm64)

echo "build.sh: compiling optional x86_64 slice"
if build_arch x86_64; then
  BUILT+=(x86_64)
else
  echo "build.sh: x86_64 slice did not build. Continuing with arm64 only." >&2
fi

if [ "${#BUILT[@]}" -eq 1 ]; then
  cp "$TMP/GreylineHub-arm64" "$ROOT/MacOS/GreylineHub"
else
  run_cmd lipo -create "$TMP/GreylineHub-arm64" "$TMP/GreylineHub-x86_64" -output "$ROOT/MacOS/GreylineHub"
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

# WallpaperAgent loads /Library/Screen Savers before the home-folder copy.
# An old root-owned bundle there is what the screen actually runs.
SYSTEM_SAVER="/Library/Screen Savers/GreylineHub.saver"
if [ -d "$SYSTEM_SAVER" ]; then
  plist="$SYSTEM_SAVER/Contents/Info.plist"
  short="?"
  build="?"
  if [ -f "$plist" ]; then
    short="$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)"
    build="$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true)"
    [ -n "$short" ] || short="?"
    [ -n "$build" ] || build="?"
  fi
  echo
  echo "WARNING: macOS loads this system-wide saver instead of ~/Library/Screen Savers/GreylineHub.saver:"
  echo "  ${SYSTEM_SAVER}"
  echo "  version ${short} (${build})"
  echo "Remove it with:"
  echo "  sudo rm -rf /Library/Screen\\ Savers/GreylineHub.saver"
fi
