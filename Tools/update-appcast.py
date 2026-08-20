#!/usr/bin/env python3
"""Insert or replace one Sparkle appcast <item> for a release.

    Tools/update-appcast.py --archive .build-release/Inkstone-0.1.0.dmg \\
        --version 0.1.0 --build 1 \\
        --url https://github.com/iamzifei/inkstone/releases/download/v0.1.0/Inkstone-0.1.0.dmg

Why not Sparkle's own `generate_appcast`: it derives each enclosure URL as
`--download-url-prefix` + filename, one prefix for every file in the directory.
GitHub release downloads live under a *per-tag* path, so a single prefix is
correct for exactly one version and wrong for every older item it rewrites. This
takes the URL per item instead.

The signature comes from `sign_update`, which reads the EdDSA private key from
the login keychain — the same key AudioSwitch, Candela and ClipStack sign with.
No key file is passed anywhere, so none can be left on disk.

Items are kept newest-first and deduplicated by version, so re-running for a
version that is already present replaces it rather than adding a second entry
that Sparkle would have to pick between.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from email.utils import formatdate
from pathlib import Path
from xml.etree import ElementTree as ET

# stdlib ElementTree, not defusedxml, deliberately. The only document this ever
# parses is appcast.xml from this repository — written by this script, committed,
# and reviewed. It is never fetched from the network and never attacker-supplied,
# so the XXE and entity-expansion classes defusedxml guards against have no way
# in, and ElementTree does not resolve external entities in any case. If this ever
# grows a mode that reads a feed from a URL, that reasoning stops holding and the
# dependency becomes worth adding.

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{sparkle}" xmlns:dc="{dc}">
  <channel>
    <title>Inkstone</title>
    <link>https://inkslab.app/appcast.xml</link>
    <description>Most recent Inkstone updates.</description>
    <language>en</language>
  </channel>
</rss>
""".format(sparkle=SPARKLE_NS, dc=DC_NS)


def ed_signature(sign_tool: Path, archive: Path) -> str:
    """The base64 EdDSA signature for the archive.

    `sign_update` prints an XML attribute fragment rather than a bare signature —
    `sparkle:edSignature="…" length="…"` — so the value is pulled out of it. It
    exits non-zero if the keychain has no key, which is the failure worth having:
    an unsigned appcast is one every client will refuse.
    """
    out = subprocess.run([str(sign_tool), str(archive)],
                         capture_output=True, text=True, check=True).stdout
    for part in out.split():
        if part.startswith("sparkle:edSignature="):
            return part.split("=", 1)[1].strip('"')
    raise SystemExit(f"could not find a signature in sign_update output: {out!r}")


def version_key(item: ET.Element) -> tuple:
    """Sort key: numeric where the version is numeric, so 0.10.0 > 0.9.0."""
    raw = (item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") or "0")
    parts = []
    for chunk in raw.split("."):
        parts.append(int(chunk) if chunk.isdigit() else 0)
    return tuple(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", default="appcast.xml", type=Path)
    ap.add_argument("--archive", required=True, type=Path)
    ap.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 0.1.0")
    ap.add_argument("--build", required=True, help="CFBundleVersion, e.g. 1")
    ap.add_argument("--url", required=True, help="public download URL for this archive")
    ap.add_argument("--min-system", default="26.0")
    ap.add_argument("--sign-tool", default=".sparkle-tools/sign_update", type=Path)
    args = ap.parse_args()

    if not args.archive.is_file():
        raise SystemExit(f"no such archive: {args.archive}")
    if not args.sign_tool.is_file():
        raise SystemExit(f"no sign_update at {args.sign_tool} — run Tools/fetch-sparkle-tools.sh")

    signature = ed_signature(args.sign_tool, args.archive)
    length = args.archive.stat().st_size

    if args.appcast.exists():
        tree = ET.ElementTree(ET.fromstring(args.appcast.read_text(encoding="utf-8")))
    else:
        tree = ET.ElementTree(ET.fromstring(EMPTY))
    channel = tree.getroot().find("channel")

    # Replace rather than append, so re-running a release does not leave two
    # items claiming the same version.
    for existing in channel.findall("item"):
        if existing.findtext(f"{{{SPARKLE_NS}}}shortVersionString") == args.version:
            channel.remove(existing)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = formatdate(localtime=False, usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.min_system
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        f"{{{SPARKLE_NS}}}edSignature": signature,
        "length": str(length),
        "type": "application/octet-stream",
    })
    channel.append(item)

    items = sorted(channel.findall("item"), key=version_key, reverse=True)
    for existing in channel.findall("item"):
        channel.remove(existing)
    for existing in items:
        channel.append(existing)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    args.appcast.write_text(args.appcast.read_text(encoding="utf-8").rstrip() + "\n",
                            encoding="utf-8")

    print(f"appcast: {args.version} (build {args.build}), {length} bytes")
    print(f"  {args.url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
