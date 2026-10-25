#!/usr/bin/env python3 -I
"""Vendor every registry crate in a Cargo.lock into a cargo directory source.

Each .crate file is taken from a seed folder when one holds it, otherwise fetched with
/usr/bin/curl from static.crates.io, and always checked against the Cargo.lock SHA-256
before it is unpacked. Cargo then builds offline from the folder.

Usage: vendor-crates.py <Cargo.lock> <out-dir> [<seed-dir-of-.crate-files>]
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor


def parse_lock(text):
    """name, version, source and checksum of every [[package]] (no tomllib on older Pythons)."""
    packages = []
    for block in text.split("[[package]]")[1:]:
        packages.append(dict(re.findall(r'^(name|version|source|checksum) = "([^"]*)"', block, re.M)))
    return packages


def registry_packages(lock_text):
    return [p for p in parse_lock(lock_text) if p.get("source", "").startswith("registry+")]


def safe_members(archive):
    members = archive.getmembers()
    for m in members:
        if m.name.startswith("/") or ".." in m.name.split("/") or not (m.isfile() or m.isdir()):
            raise ValueError(f"unsafe member {m.name}")
    return members


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def vendor(package, out, seed):
    name, version, want = package["name"], package["version"], package["checksum"]
    dest = os.path.join(out, f"{name}-{version}")
    marker = os.path.join(dest, ".cargo-checksum.json")
    if os.path.exists(marker):
        with open(marker) as f:
            recorded = json.load(f)
        # Every file listed, so cargo re-checks each one on every build.
        if recorded.get("package") == want and recorded.get("files"):
            return None
        shutil.rmtree(dest)
    downloads = os.path.join(out, ".download")
    crate = os.path.join(downloads, f"{name}-{version}.crate")
    seeded = seed and os.path.join(seed, f"{name}-{version}.crate")
    if seeded and os.path.isfile(seeded) and sha256(seeded) == want:
        shutil.copyfile(seeded, crate)
    else:
        url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
        for _ in range(3):
            if subprocess.run(["/usr/bin/curl", "-sSfL", "--max-time", "120", "-o", crate, url]).returncode == 0:
                break
        else:
            return f"download failed: {name} {version}"
    if not os.path.isfile(crate):
        return f"download failed: {name} {version}"
    if sha256(crate) != want:
        os.remove(crate)
        return f"checksum mismatch: {name} {version}"
    try:
        with tarfile.open(crate) as archive:
            archive.extractall(out, safe_members(archive))
    except (ValueError, tarfile.TarError) as error:
        return f"refused {name} {version}: {error}"
    with open(marker, "w") as f:
        json.dump({"files": file_sums(dest), "package": want}, f)
    return None


def file_sums(folder):
    """SHA-256 of every file in an unpacked crate, by path inside it, as cargo's directory source checks."""
    sums = {}
    for root, _, names in os.walk(folder):
        for name in names:
            path = os.path.join(root, name)
            relative = os.path.relpath(path, folder)
            if relative != ".cargo-checksum.json":
                sums[relative] = sha256(path)
    return sums


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    lock, out = argv[1], argv[2]
    seed = argv[3] if len(argv) == 4 else None
    os.makedirs(os.path.join(out, ".download"), exist_ok=True)
    with open(lock) as f:
        packages = registry_packages(f.read())
    with ThreadPoolExecutor(12) as pool:
        errors = [e for e in pool.map(lambda p: vendor(p, out, seed), packages) if e]
    print(f"{len(packages)} crates checked, {len(errors)} problems")
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
