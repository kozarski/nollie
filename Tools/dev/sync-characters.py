#!/usr/bin/env python3
"""Copies the character package (built in the nollie-art repo) into the app.

    Tools/dev/sync-characters.py [path to export/out]

Defaults to ~/code/nollie-art/export/out. Writes:
  Packages/NollieCore/Sources/NollieCore/Characters/Resources/  manifest.json, face.json
  Shared/Characters.xcassets         body tiers, masters and glyphs (the apps only)
  Shared/CharacterAvatars.xcassets   the 512 px avatars (apps and notification extensions)

Both catalogs are rebuilt from scratch each time, so a look removed upstream goes away here too.
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / "code/nollie-art/export/out"
CORE = ROOT / "Packages/NollieCore/Sources/NollieCore/Characters/Resources"
CATALOG = ROOT / "Shared/Characters.xcassets"
AVATARS = ROOT / "Shared/CharacterAvatars.xcassets"
INFO = {"author": "xcode", "version": 1}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def fresh_catalog(path):
    if path.exists():
        shutil.rmtree(path)
    write_json(path / "Contents.json", {"info": INFO})


def image_set(catalog, name, files, properties=None):
    """files: [(source path, scale or None)]."""
    folder = catalog / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    images = []
    for src, scale in files:
        dest = f"{name}@{scale}{src.suffix}" if scale else f"{name}{src.suffix}"
        shutil.copyfile(src, folder / dest)
        entry = {"filename": dest, "idiom": "universal"}
        if scale:
            entry["scale"] = scale
        images.append(entry)
    contents = {"images": images, "info": INFO}
    if properties:
        contents["properties"] = properties
    write_json(folder / "Contents.json", contents)


def main():
    manifest = json.loads((SOURCE / "manifest.json").read_text())
    for name in ("manifest.json", "face.json"):
        CORE.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE / name, CORE / name)
    fresh_catalog(CATALOG)
    fresh_catalog(AVATARS)
    for look in manifest["looks"]:
        lid, files = look["id"], look["files"]
        for tier in manifest["tiers_pt"]:
            for layer in ("body", "front"):
                sources = []
                for k in manifest["scales"]:
                    rel = files["tiers"][f"{tier}@{k}x"].get(layer)
                    if rel:
                        sources.append((SOURCE / rel, f"{k}x"))
                if sources:
                    image_set(CATALOG, f"character-{lid}-{layer}-{tier}", sources)
        for layer, rel in files["master"].items():
            image_set(CATALOG, f"character-{lid}-{layer}-master", [(SOURCE / rel, None)])
        image_set(CATALOG, f"character-{lid}-glyph", [(SOURCE / files["glyph"], None)],
                  {"preserves-vector-representation": True, "template-rendering-intent": "template"})
        image_set(AVATARS, f"character-{lid}-avatar", [(SOURCE / files["avatar_512"], None)])
    print(f"Synced {len(manifest['looks'])} looks from {SOURCE}")


if __name__ == "__main__":
    main()
