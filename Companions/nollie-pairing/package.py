"""Copy only the reviewed runtime sources into the app's signed resource bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[1]
TARGET = ROOT / "Apps/Nollie" / "Resources" / "nollie-pairing.bundle"
FILES = ("__init__.py", "provider.py", "plugin.yaml", "dashboard/manifest.json", "dashboard/plugin_api.py", "dashboard/index.js")


def package(check=False):
    contents = {path: (SOURCE / path).read_bytes() for path in FILES}
    manifest = {"schema": 1, "plugin": "nollie-pairing", "version": "0.1.0", "files": [
        {"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for path, data in contents.items()]}
    contents["package.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    contents["Info.plist"] = plistlib.dumps({"CFBundleIdentifier": "com.coreykozarski.nollie.pairing-resources",
        "CFBundleName": "Nollie Pairing", "CFBundlePackageType": "BNDL", "CFBundleVersion": "1"})
    if check:
        for path, data in contents.items():
            if not (TARGET / path).is_file() or (TARGET / path).read_bytes() != data:
                raise SystemExit("Pairing resource package differs: " + path)
        actual = {str(path.relative_to(TARGET)) for path in TARGET.rglob("*") if path.is_file()}
        if actual != set(contents):
            raise SystemExit("Pairing resource package contains unexpected files.")
    else:
        for path, data in contents.items():
            target = TARGET / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    print("Pairing resource package verified." if check else "Pairing resource package saved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    package(parser.parse_args().check)
