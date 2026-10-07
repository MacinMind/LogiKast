# LogiKast: product brief for macinmind.com

Hand this file to the Claude project that maintains macinmind.com. Task: add a **LogiKast** product with three pages: **Info**, **Screenshots** and **Download**. Match the structure, styling and navigation of the existing product pages (Radiologik and others). Use U.S. English spelling everywhere (organized, color, center, gray).

## Basics

| | |
|---|---|
| Name | LogiKast |
| Publisher | MacinMind Software, Inc. |
| Price | Free. Open source, GPLv2 |
| Current version | 1.0 (public version `1.0`, build 18). Final release |
| Requires | macOS 13 Ventura or later. Universal: Apple silicon and Intel |
| Size | About 7.4 MB (DMG) |
| Bundle ID | com.macinmind.logikast |
| Signed | Developer ID (MacinMind Software, Inc.) and notarized by Apple; opens without Gatekeeper warnings |
| Source and releases | https://github.com/MacinMind/LogiKast (releases at https://github.com/MacinMind/LogiKast/releases) |
| Sparkle appcasts | Final: https://macinmind.com/pads/LogiKast.xml. Beta: https://macinmind.com/pads/LogiKastbeta.xml (published by the Feeder app; already live) |

## One-line pitch

A free Mac app that makes running an Icecast streaming server easy, built for Radiologik users.

## Longer description (for the Info page)

LogiKast wraps a bundled Icecast 2.5.0 server in a native Mac app. Nothing else needs to be installed. Radiologik (or any Icecast-compatible encoder) sends audio to LogiKast, and listeners connect to the stream. LogiKast does **no audio encoding itself**. Encoders that work with it: Radiologik, Audio Hijack, LadioCast, BUTT and BUTTM. Streams can be MP3, AAC or HE-AAC.

The server runs in the background as a per-user launch agent: it keeps running when the LogiKast window is closed or the app quits, restarts if it stops, and starts at login. The app is the control panel.

### Feature list

- One Icecast server with any number of mounts (streams). Per-mount max listeners, burst size, fallback mount and stream info (name, genre, description, URL).
- Live status for every mount, with listener counts in the Dock badge and the menu bar.
- Copy-and-paste connection details for your encoder (host, port, mount, password), plus a Setup Assistant for new stations.
- Listener list: search, see who is connected and for how long, and a Disconnect button. Tested with 1,000 listeners.
- Bandwidth meter, per stream and total (only works while the window is open, so it costs nothing in the background).
- A button that opens Icecast's own web admin page already signed in.
- Backup audio: a file that plays automatically when the encoder drops and hands back to live when the encoder returns.
- Share links, a QR code, and ready-to-paste website player code. Optional public directory listing.
- Port and settings validation, plus plain-language problem hints (for example, naming whatever app is already using a port).
- Automatic updates through Sparkle, with an "Include beta versions" switch (Server > Updates tab). Check for Updates is in the LogiKast menu. Help menu shows Version Notes (or "Beta Version Notes") from the update feed.
- Migrates settings from the old iceKast beta automatically.

### How it works, in three steps (for a short "Getting started" section)

1. Install LogiKast and open it. The Setup Assistant creates your first mount and starts the server.
2. In your encoder, enter the connection details LogiKast shows (copy buttons provided).
3. Share the stream link, QR code, or website player code with listeners.

### Good to know

- Router and firewall: to reach listeners outside the home or studio network, forward the server's port (default 8000) to the Mac.
- Radiologik customers are the primary audience, but nothing ties LogiKast to Radiologik.
- Icecast's client limit must be more than twice a source limit; LogiKast sets valid limits for you.

## Credits and license text (put on the Info page footer)

LogiKast runs Icecast (https://icecast.org), the open source streaming server from the Xiph.Org Foundation and its contributors, under GPLv2. It also bundles libxml2, libxslt, libogg, libvorbis, libigloo, curl and RHash, each under its own license. LogiKast's source code is GPLv2. The LogiKast icon is derived from the Radiologik icon, is © MacinMind Software, Inc., all rights reserved, and is not covered by the GPL.

## Screenshots page

No marketing screenshots exist yet. The user will supply them (or ask Claude to capture the running app). Suggested set and captions:

1. Mounts overview: live status, listener counts, Out bandwidth, "On air for" duration.
2. Mount detail: Stream Info and connection details.
3. Listener list with search and Disconnect.
4. Server tab: App & Log, with the live log.
5. Updates tab with the beta switch.
6. Share page: links, QR code, website player code.
7. Setup Assistant.
8. Dock badge and menu bar status item.

Icon (square, 1024 px) is in the app repo at `Design/logikast-icon-1024.png`; the user can copy it. Smaller sizes are in `LogiKast/Assets.xcassets/AppIcon.appiconset/`.

## Download page

- Primary button: **Download LogiKast 1.0** (DMG, about 7.4 MB). Release asset on GitHub: `LogiKast-1.0.dmg`. The direct link has the form
  `https://github.com/MacinMind/LogiKast/releases/download/v1.0/LogiKast-1.0.dmg`
  (confirm against the Releases page; the tag is `v1.0`).
- SHA-256: `abcdbe661c997d209b034f6a04c0bf3d26db304241e92c7e8d99c0e8e90a5a19`
- This is a final release; no beta labeling needed.
- Install steps: open the DMG, drag LogiKast to Applications, open it. On first run, approve the background server under System Settings > General > Login Items & Extensions if macOS asks.
- Requirements line: macOS 13 or later, Apple silicon or Intel.
- Updating: the app updates itself with Sparkle. Beta 2 testers must install 1.0 manually (beta 2 had no updater).
- Link to the source and release notes on GitHub, and mention it is free and open source.
- Keep the version, size and checksum in one place on the site so each release is a single edit.

### Version notes for 1.0 (optional "What's new" section)

Ask the user for the exact notes; they are published in the appcast and the GitHub release. Highlights of the 1.0 betas: Sparkle automatic updates with a beta switch; Version Notes in the Help menu; fixes for Icecast CPU use and a web admin dashboard crash; sturdier server start-up; a refreshed window (header, status in the sidebar, Start/Stop Server button, delete mounts from the sidebar); the app was renamed from iceKast to LogiKast.

## Things not to claim

- No audio encoding, no recording, no AutoDJ or playlists. LogiKast is the server side only.
- No HTTPS/TLS and no relays yet (planned ideas, not promised).
- Not tested on macOS 13 or 14 by the author yet; say "macOS 13 or later" without promising more.
- Do not describe the app as a replacement for Radiologik. It complements it.
