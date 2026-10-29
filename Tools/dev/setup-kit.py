#!/usr/bin/env python3
"""Assemble the Setup Kit the Direct Mac edition carries for a managed setup.

    python3 Tools/dev/setup-kit.py <destination>

<destination>/hermes-overlay   Nollie's reviewed Hermes changes (Services/Runtime/HermesOverlay)
<destination>/add-ons          the managed add-ons from Tools/pins.json, their installer
                               (Services/Runtime/managed_addons.py) and kit.json, which lists
                               every file with its size and SHA-256

The app checks overlay.json against NativeSetupPlan.hermesOverlayDigest and every add-on file
against kit.json before it writes anything into a setup. Standard library only.
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
COMPANIONS = ROOT / "Companions"
SKIP_PARTS = {"tests", "__pycache__"}
# What each add-on's own installer copies; the managed setup copies the same files.
SELECTION = {
    "nollie-workflow": None,  # the whole folder
    "nollie-reader": None,
    "nollie-crew": ["__init__.py", "plugin.yaml", "crew.py", "handoffs.py", "hermes_profiles.py", "policy.py", "workflow.py",
                    "profiles.py", "store.py", "tools.py", "dashboard"],
    "nollie-computer": ["__init__.py", "plugin.yaml", "dashboard"],
    "nollie-mac": ["__init__.py", "plugin.yaml", "server.py"],
}


def managed_names(pins=ROOT / "Tools" / "pins.json"):
    items = json.loads(Path(pins).read_text())["addons"]["items"]
    return [item["name"] for item in items if item["managed"]]


def addon_files(name):
    folder = COMPANIONS / name
    chosen = SELECTION[name]
    roots = [folder] if chosen is None else [folder / part for part in chosen]
    files = []
    for root in roots:
        candidates = [root] if root.is_file() else sorted(root.rglob("*"))
        for path in candidates:
            relative = path.relative_to(folder)
            if path.is_symlink():
                raise SystemExit(f"Refusing a linked file in {name}: {relative}")
            if (not path.is_file() or SKIP_PARTS & set(relative.parts) or path.suffix == ".pyc"
                    or path.name in (".DS_Store", "recorder-only") or (chosen is None and relative.as_posix() == "install.py")):
                continue
            files.append(relative.as_posix())
    return sorted(set(files))


def entry(path, relative):
    data = Path(path).read_bytes()
    return {"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def version(name):
    for line in (COMPANIONS / name / "plugin.yaml").read_text().splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().strip('"')
    raise SystemExit(f"{name}/plugin.yaml has no version")


def build(destination):
    destination = Path(destination)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(ROOT / "Services/Runtime/HermesOverlay", destination / "hermes-overlay")
    addons = destination / "add-ons"
    addons.mkdir(parents=True)
    shutil.copy2(ROOT / "Services/Runtime/managed_addons.py", addons / "managed_addons.py")
    items = []
    names = managed_names()
    if set(names) - set(SELECTION):
        raise SystemExit("Tools/pins.json marks an add-on managed that the kit does not know how to copy.")
    for name in names:
        files = []
        for relative in addon_files(name):
            target = addons / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(COMPANIONS / name / relative, target)
            files.append(entry(target, f"{name}/{relative}"))
        items.append({"name": name, "version": version(name), "files": files})
    kit = {"schema": 1,
           "installer": entry(addons / "managed_addons.py", "managed_addons.py"),
           "readerLock": entry(addons / "nollie-reader/requirements.txt", "nollie-reader/requirements.txt"),
           "items": items}
    (addons / "kit.json").write_text(json.dumps(kit, indent=1, sort_keys=True) + "\n")
    return kit


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    kit = build(sys.argv[1])
    print("Setup Kit: " + ", ".join(f"{item['name']} {item['version']}" for item in kit["items"]))


if __name__ == "__main__":
    main()
