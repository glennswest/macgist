#!/bin/bash
# Builds build/MacGist.app (universal, ad-hoc signed). macOS-only target, so
# this runs on the Mac rather than the Linux build box.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
ARCHS=(--arch arm64 --arch x86_64)

# Command Line Tools 27.x ship no SwiftUIMacros compiler plugin, so SwiftUI
# cannot build against the 27.x SDK without full Xcode. Pin the 26 SDK then.
CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
      && -d "$CLT/SDKs/MacOSX26.sdk" ]]; then
  export SDKROOT="$CLT/SDKs/MacOSX26.sdk"
fi
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/MacGist"

APP=build/MacGist.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacGist"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime --timestamp=none "$APP"
echo "built $APP ($VERSION)"
