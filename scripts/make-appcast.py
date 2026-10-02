#!/usr/bin/env python3
"""Maintains LogiKast's Sparkle appcasts.

  scripts/make-appcast.py add <dmg> --channel beta|final --notes "Item one" --notes "Item two" [--date YYYY-MM-DD]
      Signs the DMG with the EdDSA key in your login keychain, records it in appcast/releases.json, and rewrites
      appcast/LogiKast.xml (final releases only) and appcast/LogiKastbeta.xml (betas and finals).
  scripts/make-appcast.py build
      Rewrites the two XML files from appcast/releases.json.

Upload both XML files to https://macinmind.com/pads/ after every release.
The version numbers come from project.yml; the DMG is expected at the matching GitHub release URL."""
import argparse, datetime, html, json, re, subprocess, sys, tarfile
from email.utils import format_datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RELEASES = ROOT / "appcast" / "releases.json"
SPARKLE_TARBALL = ROOT / "third_party" / "src" / "Sparkle-2.10.0.tar.xz"
SPARKLE_DIR = ROOT / "build" / "sparkle"
REPO = "MacinMind/LogiKast"
MIN_SYSTEM = "13.0"

def yml(key):
    m = re.search(rf'^\s*{key}:\s*"([^"]+)"', (ROOT / "project.yml").read_text(), re.M)
    if not m: sys.exit(f"error: {key} not found in project.yml")
    return m.group(1)

def sign_update():
    tool = SPARKLE_DIR / "bin" / "sign_update"
    if not tool.exists():
        SPARKLE_DIR.mkdir(parents=True, exist_ok=True)
        with tarfile.open(SPARKLE_TARBALL) as t: t.extractall(SPARKLE_DIR)
    return tool

def load():
    return json.loads(RELEASES.read_text()) if RELEASES.exists() else []

def item_xml(r):
    notes = "".join(f"<li>{html.escape(n)}</li>" for n in r["notes"])
    date = format_datetime(datetime.datetime.fromisoformat(r["date"]).replace(hour=12, tzinfo=datetime.timezone.utc))
    return f"""    <item>
      <title>Version {html.escape(r['short'])}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{r['version']}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(r['short'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{r['minSystem']}</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>{notes}</ul>]]></description>
      <enclosure url="{html.escape(r['url'])}" length="{r['length']}" type="application/octet-stream" sparkle:edSignature="{r['edSignature']}"/>
    </item>
"""

def feed_xml(items, title):
    body = "".join(item_xml(r) for r in items)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschek.com/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>{title}</title>
    <link>https://github.com/{REPO}</link>
    <description>Updates for LogiKast</description>
    <language>en</language>
{body}  </channel>
</rss>
"""

def build():
    rel = sorted(load(), key=lambda r: [int(x) for x in r["version"].split(".")], reverse=True)
    (ROOT / "appcast" / "LogiKast.xml").write_text(feed_xml([r for r in rel if r["channel"] == "final"], "LogiKast"))
    (ROOT / "appcast" / "LogiKastbeta.xml").write_text(feed_xml(rel, "LogiKast (including betas)"))
    print(f"wrote appcast/LogiKast.xml ({sum(r['channel'] == 'final' for r in rel)} final) and appcast/LogiKastbeta.xml ({len(rel)} total)")

def add(a):
    dmg = Path(a.dmg)
    out = subprocess.run([str(sign_update()), str(dmg)], capture_output=True, text=True, timeout=120)
    if out.returncode != 0: sys.exit(f"error: sign_update failed:\n{out.stderr or out.stdout}")
    sig = re.search(r'sparkle:edSignature="([^"]+)"', out.stdout)
    length = re.search(r'length="(\d+)"', out.stdout)
    if not sig or not length: sys.exit(f"error: unexpected sign_update output: {out.stdout}")
    short, version = yml("MARKETING_VERSION"), yml("CURRENT_PROJECT_VERSION")
    entry = {"version": version, "short": short, "channel": a.channel, "date": a.date or datetime.date.today().isoformat(),
             "url": f"https://github.com/{REPO}/releases/download/v{short}/{dmg.name}", "length": int(length.group(1)),
             "edSignature": sig.group(1), "minSystem": MIN_SYSTEM, "notes": a.notes}
    rel = [r for r in load() if r["version"] != version]
    rel.append(entry)
    RELEASES.write_text(json.dumps(rel, indent=2) + "\n")
    print(f"recorded {short} ({version}) as {a.channel}")
    build()

p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
x = sub.add_parser("add"); x.add_argument("dmg"); x.add_argument("--channel", choices=["beta", "final"], required=True)
x.add_argument("--notes", action="append", required=True); x.add_argument("--date")
sub.add_parser("build")
args = p.parse_args()
add(args) if args.cmd == "add" else build()
