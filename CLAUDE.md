# MacGist — project context

Native macOS menu-bar app (Swift/AppKit, SwiftPM): **local gists**. Highlight
text anywhere, or select files/folders in Finder → right-click → **Services →
Copy to Gist** → `http://<lan-ip>:8642/g/<token>` on the clipboard. The link
opens a gist page (inline highlighted text, images, download cards, zip of
all) and expires after 15 minutes. LAN only, served by the app itself.

## Build exception
This is a macOS app, so it builds **on the Mac** (the cross-project "build on
dev" rule exists because those targets are Linux; this target is macOS).
`scripts/build-app.sh` → `build/MacGist.app`; `scripts/install.sh` installs it.

## Version
Single source: `VERSION` (stamped into `Info.plist` by `scripts/build-app.sh`).

## Design
- `MacGistCore` (testable): `Gist`/`GistStore` (in-memory, lock-guarded),
  `GistBuilder` (snippets + files; folders zipped into the gist's temp dir),
  `HTTPServer` (Network.framework, GET/HEAD, single Range, Connection: close),
  `GistPage` (HTML + curl listing). `MacGist`: AppDelegate, menu, Services.
- Routes: `/g/<t>` page (curl gets the raw file for 1-file gists, a URL list otherwise),
  `/g/<t>/raw/<i>/<name>`, `/g/<t>/dl/<i>/<name>`, `/g/<t>/zip/<name>` (built lazily).
- **One** `NSServices` entry (`copyToGist`) takes both file and text types.
  Two services with the same title collided: lookup by name hit the files one.
- Raw text is always `text/plain` + nosniff (no stored XSS via shared .html/.svg).
- Highlighting is highlight.js from cdnjs, loaded by the viewer; without it the page falls back to plain `<pre>`.
- Default port 8642 (8765 collided with another local service).
- Inbox: `Inbox` (token, subnets, sender names, saving) + `ChunkedDecoder`; server's
  `handleInbox`/`readBody`. Sender names need macOS 15 **Local Network** permission
  (the reverse-DNS query to the LAN resolver is held until granted). Don't cache failures.
- Settings: `Prefs` (keys, defaults, clamping) is the only place defaults are read. Observe
  them with KVO; `UserDefaults.didChangeNotification` misses `defaults write` from outside.
- Releases: `scripts/release.sh` builds, zips (`ditto`) and attaches `MacGist.zip` to the GitHub release.
- `/usr/bin/log` must be spelled out in zsh (`log` is a shell builtin there).

## Work plan
- [x] v0.1.0: menu-bar app, Copy to Gist service (text + files), gist page, 15-min expiry, zip, tests, scripts
- [x] v0.3.0: **inbox**, per issue #1. Token-protected (`/in/<token>/…`,
  constant-time compare, any other `/in/...` → 403), LAN-only (source IP must be in one of
  the Mac's interface subnets, or `inboxSubnets` CIDRs).
  `PUT /in/<t>/<name>` → `~/Downloads/From <sender>/<name>` (sender = reverse-DNS first label,
  no overwrite) → `201 {"saved","bytes"}`; `POST /in/<t>/clipboard` (≤1 MiB) → NSPasteboard,
  `?title=`, `204`; `GET /in/<t>/ping` → 200; `GET /in/<t>/` → browser send page.
  Caps: 1 GiB/file (`maxUploadMB`). Chunked + Content-Length, `Expect: 100-continue`, 60 s idle.
  Token in `~/Library/Application Support/MacGist/inbox-token` (0600); menu: copy token / send link, reset.
- [x] v0.4.0: **everything settable, any network**. Native Settings window (⌘,):
  gist lifetime (also a quick menu + "Extend" per gist), port (live server restart), link host
  (Automatic / a specific interface by name / .local name / custom), inbox on/off, allowed
  subnets (auto or list), file + clipboard caps, receive folder, highlighter URL (blank = off).
  Menu status computed live; "Copy Link via <other address>" for multi-homed Macs; links use
  the current address, not the one at creation.
- [x] Public (v0.5.0): history squashed to one commit, issue #1 genericized. Inbox default scope = any RFC 1918 network (owner has many 192.168.x subnets).
- [ ] Later: optional Finder Sync extension for a top-level context-menu item (needs a signing identity)
- [ ] Later: configurable lifetime in the menu
