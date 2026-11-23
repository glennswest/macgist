#!/bin/bash
# Runs the test suite with Command Line Tools alone (no Xcode): pins the 26 SDK
# when CLT lacks the SwiftUIMacros plugin (same dance as build-app.sh) and
# points the compiler at the toolchain's Swift Testing macro plugin, which CLT
# keeps in a subdirectory the compiler does not search by default.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
      && -d "$CLT/SDKs/MacOSX26.sdk" ]]; then
  export SDKROOT="$CLT/SDKs/MacOSX26.sdk"
fi

EXTRA=()
TESTING_PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"
[[ -d "$TESTING_PLUGINS" ]] && EXTRA+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")

exec swift test "${EXTRA[@]}" "$@"
