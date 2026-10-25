#!/usr/bin/env python3
"""Checks an appcast.xml against the release it is for. Offline; reads nothing secret.

    python3 -I Tools/release/check_appcast.py appcast.xml --tag v0.2 [--zip Nollie.zip]

The newest item must be this tag's version, point at this tag's Nollie.zip, carry an EdDSA signature
and (given the zip) the zip's exact length.
"""
import argparse
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO_DOWNLOADS = "https://github.com/kozarski/nollie/releases/download/"


def problems(appcast_text, tag, zip_size=None):
    try:
        root = ET.fromstring(appcast_text)
    except ET.ParseError as error:
        return [f"appcast.xml is not well-formed XML ({error})."]
    items = root.findall("./channel/item")
    if not items:
        return ["appcast.xml has no items."]
    version = tag.lstrip("v")
    mine = [item for item in items if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version]
    if not mine:
        return [f"appcast.xml has no item for version {version}."]
    item = mine[0]
    found = []
    enclosure = item.find("enclosure")
    if enclosure is None:
        return [f"The item for {version} has no download."]
    if enclosure.get("url") != f"{REPO_DOWNLOADS}{tag}/Nollie.zip":
        found.append(f"The download is {enclosure.get('url')}, not this release's Nollie.zip.")
    if not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        found.append("The download has no EdDSA signature.")
    if zip_size is not None and enclosure.get("length") != str(zip_size):
        found.append(f"The listed length {enclosure.get('length')} is not the zip's {zip_size} bytes.")
    if not item.findtext(f"{{{SPARKLE}}}version"):
        found.append("The item has no build number.")
    # The newest item is the first one Sparkle offers.
    if items[0] is not item:
        found.append(f"Version {version} is not the newest item in the feed.")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("appcast")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--zip")
    args = parser.parse_args()
    size = Path(args.zip).stat().st_size if args.zip else None
    found = problems(Path(args.appcast).read_text(), args.tag, size)
    for line in found:
        print("error: " + line, file=sys.stderr)
    if not found:
        print(f"appcast.xml is fit for {args.tag}.")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
