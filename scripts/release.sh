#!/bin/bash
# Builds MacGist.app and publishes it as a GitHub release for the tag vX.Y.Z
# matching VERSION. Release notes come from that version's CHANGELOG section.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
git rev-parse "$TAG" >/dev/null 2>&1 || { echo "tag $TAG missing" >&2; exit 1; }

./scripts/build-app.sh
rm -f build/MacGist.zip
ditto -c -k --sequesterRsrc --keepParent build/MacGist.app build/MacGist.zip

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
awk -v tag="$TAG" '
    $0 ~ "^## \\[" tag "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<'NOTE'

### Install
Download `MacGist.zip`, unzip it, and move `MacGist.app` to `/Applications`. The app is ad-hoc signed and not notarized, so the first launch is blocked. Click **Open Anyway** in System Settings → Privacy & Security, or run:

```sh
xattr -dr com.apple.quarantine /Applications/MacGist.app && open /Applications/MacGist.app
```

Requires macOS 13 or later (universal: Apple silicon and Intel).
NOTE

gh release create "$TAG" build/MacGist.zip --title "MacGist $VERSION" --notes-file "$NOTES"
