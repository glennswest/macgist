#!/bin/bash
# Builds build/MacGist.app (universal, ad-hoc signed). macOS-only target, so
# this runs on the Mac rather than the Linux build box.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
ARCHS=(--arch arm64 --arch x86_64)
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
