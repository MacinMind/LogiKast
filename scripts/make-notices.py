#!/usr/bin/env python3
"""Builds LogiKast/Resources/ThirdPartyNotices.txt from the license files inside the pinned source tarballs in
third_party/src (downloaded by scripts/build-icecast.sh). Run after changing a bundled library's version.
Usage: scripts/make-notices.py"""
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "third_party" / "src"
OUT = ROOT / "LogiKast" / "Resources" / "ThirdPartyNotices.txt"

# (name, tarball prefix, license files inside the tarball, homepage, what it is, license name)
PARTS = [
    ("Icecast 2.5.0", "icecast-2.5.0", [],
     "https://icecast.org", "the streaming server LogiKast runs. Copyright Xiph.Org Foundation and contributors.", "GNU GPL version 2 (full text below). Its bundled avl, net, timing and thread libraries are under the GNU Library GPL version 2 (text under libigloo, below)."),
    ("libigloo 0.9.5", "libigloo-0.9.5", ["COPYING"], "https://icecast.org/igloo/", "support library for Icecast.", "GNU Library GPL version 2"),
    ("libogg 1.3.6", "libogg-1.3.6", ["COPYING"], "https://xiph.org/ogg/", "Ogg container library.", "BSD 3-clause"),
    ("libvorbis 1.3.7", "libvorbis-1.3.7", ["COPYING"], "https://xiph.org/vorbis/", "Vorbis audio library.", "BSD 3-clause"),
    ("libxml2 2.13.9", "libxml2-2.13.9", ["Copyright"], "https://gitlab.gnome.org/GNOME/libxml2", "XML library.", "MIT"),
    ("libxslt 1.1.43", "libxslt-1.1.43", ["Copyright"], "https://gitlab.gnome.org/GNOME/libxslt", "XSLT library (Icecast's web pages).", "MIT"),
    ("curl 8.22.0", "curl-8.22.0", ["COPYING"], "https://curl.se", "network library.", "curl license (MIT-style)"),
    ("RHash 1.4.6", "RHash-1.4.6", ["COPYING"], "https://github.com/rhash/RHash", "hashing library.", "BSD Zero Clause"),
]
TARBALLS = {"icecast-2.5.0": "icecast-2.5.0.tar.gz", "libigloo-0.9.5": "libigloo-0.9.5.tar.gz", "libogg-1.3.6": "libogg-1.3.6.tar.xz",
            "libvorbis-1.3.7": "libvorbis-1.3.7.tar.xz", "libxml2-2.13.9": "libxml2-2.13.9.tar.xz", "libxslt-1.1.43": "libxslt-1.1.43.tar.xz",
            "curl-8.22.0": "curl-8.22.0.tar.xz", "RHash-1.4.6": "v1.4.6.tar.gz"}

def read(tar, member):
    return tar.extractfile(member).read().decode("utf-8", "replace").rstrip()

lines = ["LogiKast third-party notices", "=" * 28, "",
         "LogiKast is free software under the GNU General Public License version 2 (the full text is below).",
         "Source code: https://github.com/MacinMind/LogiKast",
         "",
         "LogiKast bundles Icecast and the libraries listed here. Each is used under its own license.",
         "Icecast's source, the exact versions bundled, and the three small patches LogiKast applies (third_party/patches in the",
         "repository, with scripts/build-icecast.sh) are available from https://icecast.org and from the LogiKast repository.",
         "", ""]
for name, prefix, files, home, what, lic in PARTS:
    lines += ["-" * 72, f"{name} - {what}", f"{home}", f"License: {lic}", "-" * 72, ""]
    with tarfile.open(SRC / TARBALLS[prefix]) as tar:
        for f in files:
            if f == "COPYING" and prefix == "icecast-2.5.0": continue
            lines += [f"[{f}]", read(tar, f"{prefix}/{f}"), ""]
    lines.append("")

lines += ["-" * 72, "GNU General Public License version 2 (applies to LogiKast and Icecast)", "-" * 72, "", (ROOT / "LICENSE").read_text().rstrip(), ""]
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines))
print("wrote", OUT, f"({OUT.stat().st_size // 1024} KB)")
