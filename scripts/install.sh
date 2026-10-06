#!/bin/bash
# Builds and installs MacGist.app, registers its "Copy to Gist" services and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x MacGist 2>/dev/null || true
sleep 1

rm -rf "$DEST/MacGist.app"
cp -R build/MacGist.app "$DEST/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/MacGist.app"
/System/Library/CoreServices/pbs -update
open "$DEST/MacGist.app"
echo "installed $DEST/MacGist.app"
