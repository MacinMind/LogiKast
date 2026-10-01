# iceKast – Plan

Free, GPLv2 macOS GUI wrapper around Icecast, aimed at Radiologik customers who want an easy
station setup. No audio encoding (BUTT, Audio Hijack, LadioCast etc. handle that).

## Decisions
- Swift + SwiftUI, minimum macOS 13, universal (arm64 + x86_64).
- One Icecast server, many mounts.
- Direct distribution: Developer ID signed + notarized DMG ("MacinMind Software, Inc.").
- Public GPLv2 repo (Icecast is GPLv2, so source must be available).
- Formats: MP3, AAC, HE-AAC pass through untouched. The encoder decides the format; iceKast never sets or forces it, it only detects and displays it.
- Icecast and all libraries are built from source, statically linked, bundled in the app.
  No Homebrew or other installs for the end user.

## Versioning
Public `MAJOR.MINORbN` (beta) or `MAJOR.MINOR` (final); internal build `MAJOR.MINOR.PATCH.BUILD.BETA`.
`scripts/bump-version.sh beta|final|start X.Y [--commit]` updates project.yml and the README, and with
`--commit` commits and tags `vX`. Run when cutting a release build, not on every commit.

## Bundled binary (scripts/build-icecast.sh)
libogg, libvorbis (required by Icecast's configure), libxml2, libxslt, rhash, libigloo, curl
(HTTP only, for YP directory listing), icecast 2.5.0. Sources pinned + SHA256 in third_party/SHA256SUMS.
Patches in third_party/patches (macOS pthread fixes).
No OpenSSL: Apache-2.0 OpenSSL 3 is incompatible with GPLv2-only. HTTPS listeners are deferred;
options later: mbedTLS (Apache-2.0 / GPLv2+ dual) or a reverse proxy.

## App architecture
1. Config model (Codable): server, ports, limits, auth, mounts (max listeners, burst, fallback,
   stream info, public/YP).
2. Config writer -> icecast.xml in ~/Library/Application Support/iceKast/.
3. Service controller: Icecast runs as a per-user launch agent (SMAppService, plist in
   Contents/Library/LaunchAgents, started via Helpers/icekast-launch which execs icecast with the
   config in Application Support). It survives app quit/crash, restarts if it dies, starts at login.
   Start = register, Stop = unregister, Apply = SIGHUP (port change = kickstart -k).
4. Status poller: /status-json.xsl, per-mount listeners, source connected, title, peak.
5. Menu bar item (listener count, start/stop, open window); Dock badge; the app only attaches to the service.
6. UI: stream/mount sidebar, status dashboard, settings editors, setup wizard,
   "connect your encoder" panel (host/port/mount/password), dock badge for chosen mount.

## Milestones
1. [done] Icecast static build proven on arm64 (MP3 source + listener verified).
2. [done] Universal build (arm64 + x86_64, min macOS 13), iconv enabled; links only macOS system libs.
3. [done] Xcode project (XcodeGen), process manager with hot reload, status poller, server/mount UI, dock badge, 13 unit tests.
4. [done] Background service + menu bar item (verified: survives app quit, restarts after kill -9, hot reload keeps pid).
5. Setup wizard, app icon, port-conflict UX polish, visual check of dock badge, public directory (YP) settings.
6. Sign, notarize, DMG, GitHub release.
