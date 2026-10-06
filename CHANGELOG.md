# Changelog

## [Unreleased]
<!-- New unreleased changes go here -->

## [v0.5.0] — 2026-10-06

First public release.

### Changed
- The inbox now accepts senders from **any private network** (10.x, 172.16–31.x, 192.168.x) by default, so machines on other routed subnets can send. The token is still required. The new **Accept senders from** setting (`inboxScope`: `private`, `local`, `custom`) restores the old "this Mac's networks only" behaviour. An existing `inboxSubnets` list is kept as a custom scope.
- Git history squashed into a single commit for the public repository. Earlier entries below describe pre-public development.

## [v0.4.0] — 2026-10-06

### Added
- **Settings window** (menu → Settings…, ⌘,, or open the app again), applied live
- Settable gist lifetime (1 min to 7 days), menu quick-pick, and per-gist **Extend**
- Settable link address: automatic (default route), a specific interface, the Bonjour name, or custom; **Copy Link via** other addresses; the menu lists every address the Mac is reachable on
- Settable port (the server restarts live), inline-preview size, highlighter URL (empty = off, no internet needed), receive folder, clipboard cap
- Inbox subnets editable in Settings (automatic = this Mac's networks, re-read per request)
- MIT license; public README with usage, settings, security model, troubleshooting and screenshots
- 6 new tests (36 total)

### Changed
- Links are built from the Mac's *current* address when copied, so they keep working after a network change
- Expired-gist page no longer mentions a fixed 15 minutes

### Fixed
- Settings changed with `defaults write` (outside the app) were not applied until restart; preferences are now observed with KVO

## [v0.3.0] — 2026-10-06

### Added
- Inbox (#1): `PUT /in/<token>/<name>` saves to `~/Downloads/From <sender>/` (no overwrite, `201 {"saved","bytes"}`); `POST /in/<token>/clipboard` puts text on the Mac clipboard (`?title=`, `204`); `GET /in/<token>/ping`; browser **Send to this Mac** page at `/in/<token>/`
- Inbox security: persistent shared token (0600 file) with constant-time compare and a uniform `403`; source IP must be in a local subnet (`inboxSubnets` override); 1 GiB file cap (`maxUploadMB`), 1 MiB clipboard cap; safe basenames only
- Chunked request bodies (`curl -T -`), `Expect: 100-continue`, 60 s body idle timeout
- Menu: Receive from Network toggle, Copy Send-to-Mac Link, Copy Inbox Token, Reset Inbox Token, last five arrivals; notifications for arrivals (click to show in Finder)
- 15 new tests (30 total), including curl-driven end-to-end inbox tests

### Fixed
- Sender names: a failed reverse-DNS lookup was cached for the app's lifetime. On macOS 15 the first lookup fails until Local Network access is granted, so only successful lookups are cached now; added `NSLocalNetworkUsageDescription`
- `install.sh` no longer quits the app via AppleEvents (it tripped a TCC check); it uses `pkill`

## [v0.2.0] — 2026-10-06

### Breaking
- Renamed the project from MacToWeb to **MacGist**: app `MacGist.app`, bundle id `com.glennswest.macgist` (settings move to that defaults domain), targets `MacGist`/`MacGistCore`, GitHub repo `glennswest/macgist`

## [v0.1.0] — 2026-10-06

### Added
- Menu-bar app (`LSUIElement`) with a **Copy to Gist** service for highlighted text in any app and for files and folders in Finder
- Local HTTP server (port 8642): gist page with highlighted text, inline images, download cards and "Download all (.zip)"; Raw and Download routes; Range support
- Links are 128-bit random tokens that expire after 15 minutes; expired gists' temp files are removed
- curl/wget get the raw file for one-file gists and a URL listing otherwise
- Menu: active gists with time left and hits, Copy Link, Open in Browser, Revoke, Revoke All, Copy to Gist from Clipboard, Open at Login
- `scripts/build-app.sh` (universal, ad-hoc signed bundle), `scripts/install.sh`, `scripts/perform-service.swift`
- 15 tests, including end-to-end tests against a real server

### Fixed
- Text and file services shared the title "Copy to Gist", and lookup by name resolved to the files one; merged into a single service

### 2026-10-06
- **chore:** Project scaffold, work plan
