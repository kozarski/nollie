#!/usr/bin/env python3
"""Which pins in Tools/pins.json are behind upstream, and does the repo agree with them?

    python3 Tools/dev/check-latest.py            both checks
    python3 Tools/dev/check-latest.py --local    only the offline check that every place follows pins.json
    python3 Tools/dev/check-latest.py --upstream only the upstream report (GitHub releases, PyPI)

Read-only: it never edits a pin, downloads a release or installs anything. Upstream reads use the
public GitHub and PyPI APIs (set GITHUB_TOKEN for a higher GitHub rate limit; it is never printed).
Exit status: 1 when the repo disagrees with pins.json; 0 otherwise, even when pins are behind,
unless --strict is given. A newer upstream release is a candidate, not an instruction: read its
notes, run Tools/dev/managed-setup-dry-run.py and the tests, then bump.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import urllib.request

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pinslib", HERE / "pinslib.py")
pinslib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinslib)
ROOT = pinslib.ROOT


def read(relative):
    return (ROOT / relative).read_text()


def env_file(relative):
    return dict(line.split("=", 1) for line in read(relative).splitlines() if re.match(r"^[A-Z0-9_]+=", line))


def local_problems(pins=None):
    """Every place a pin is written down, compared with pins.json. Returns readable problems."""
    pins = pins or pinslib.load()
    get = lambda name: pinslib.component(pins, name)  # noqa: E731
    uv, python, hermes, cua, rust = (get(n) for n in ("uv", "python", "hermes", "cua-driver", "rust"))
    problems = []

    def expect(condition, where, what):
        if not condition:
            problems.append(f"{where}: {what}")

    swift_path = "Apps/Nollie/Connect/NativeDependencyInstaller.swift"
    swift = read(swift_path)

    def artifact(identifier):
        match = re.search(r'static let %s = Artifact\(id: "%s", version: "([^"]+)",\s*url: URL\(string: "([^"]+)"[^)]*\)!,\s*'
                          r'sha256: "([0-9a-f]{64})", bytes: ([0-9_]+)\)' % (identifier, identifier), swift)
        return match.groups() if match else None

    found = artifact("uv")
    expect(found and found[0] == uv["version"] and found[1] == uv["artifact"]["url"] and found[2] == uv["artifact"]["sha256"]
           and int(found[3].replace("_", "")) == uv["artifact"]["bytes"], swift_path, "uv artifact differs from pins.json")
    found = artifact("hermes")
    commit = re.search(r'static let hermesCommit = "([0-9a-f]{40})"', swift)
    expect(commit and commit.group(1) == hermes["commit"], swift_path, "hermesCommit differs from pins.json")
    expect(found and found[0] == hermes["version"] and found[2] == hermes["artifact"]["sha256"]
           and int(found[3].replace("_", "")) == hermes["artifact"]["bytes"]
           and hermes["artifact"]["url"].endswith(hermes["commit"]), swift_path, "hermes artifact differs from pins.json")
    expect(f'static let pythonVersion = "{python["version"]}"' in swift, swift_path, "pythonVersion differs from pins.json")
    expect(f'static let pythonKey = "{python["key"]}"' in swift, swift_path, "pythonKey differs from pins.json")
    expect(f"uv {uv['version']}." in swift and f"Python {python['version']}." in swift and f"Hermes {hermes['version']} " in swift,
           swift_path, "a step description names an old version")
    digest = re.search(r'static let hermesOverlayDigest = "([0-9a-f]{64})"', swift)
    expect(digest and digest.group(1) == pinslib.overlay_digest(), swift_path,
           "hermesOverlayDigest is not the SHA-256 of Services/Runtime/HermesOverlay/overlay.json")

    overlay = pinslib.overlay_manifest()
    expect(overlay["hermes"] == {"version": hermes["version"], "commit": hermes["commit"],
                                 "archiveSha256": hermes["artifact"]["sha256"]},
           "Services/Runtime/HermesOverlay/overlay.json", "built for another Hermes; run Tools/dev/hermes-overlay.py")
    for entry in overlay["files"]:
        path = pinslib.OVERLAY / "files" / entry["path"]
        expect(path.is_file() and pinslib.sha256_file(path) == entry["after"],
               "Services/Runtime/HermesOverlay", f"{entry['path']} does not match overlay.json")
    expect(set(overlay.get("exceptions", {})) == set(overlay["patches"]),
           "Services/Runtime/HermesOverlay", "each remaining patch must explain its extension gap")
    expect(not any(entry["path"].startswith("hermes_cli/") for entry in overlay["files"]),
           "Services/Runtime/HermesOverlay", "workflow helpers belong in the add-on, not Hermes source")

    pin = env_file("Tools/computer-helper/pin.env")
    expect(pin.get("DRIVER_VERSION") == cua["version"] and pin.get("DRIVER_TAG") == cua["tag"]
           and pin.get("DRIVER_COMMIT") == cua["commit"], "Tools/computer-helper/pin.env", "Cua Driver differs from pins.json")
    expect(pin.get("RUST_VERSION") == rust["version"] and pin.get("RUST_URL") == rust["artifact"]["url"]
           and pin.get("RUST_SHA256") == rust["artifact"]["sha256"], "Tools/computer-helper/pin.env", "Rust differs from pins.json")
    expect(f"tag {cua['tag']}," in read("Tools/computer-helper/NOTICE.txt"), "Tools/computer-helper/NOTICE.txt",
           "names another Cua Driver tag")

    notices = read("Docs/legal/notices.md")
    for item, label in ((hermes, "Hermes Agent"), (uv, "uv by Astral"), (python, "Python (python-build-standalone)")):
        expect(re.search(r"\| %s[^|]*\| %s\b" % (re.escape(label), re.escape(item["version"])), notices),
               "Docs/legal/notices.md", f"{label} row does not say {item['version']}")
    expect(f"`{cua['tag']}`" in notices, "Docs/legal/notices.md", f"does not name {cua['tag']}")

    lock = read("Companions/nollie-reader/requirements.txt")
    names = re.findall(r"^([A-Za-z0-9_.-]+)==\S+ \\$", lock, re.M)
    expect(names and len(names) == len(re.findall(r"^[A-Za-z0-9_.-]+==", lock, re.M)),
           "Companions/nollie-reader/requirements.txt", "every locked package needs its hashes")
    wanted = [line.strip() for line in read("Companions/nollie-reader/requirements.in").splitlines()
              if line.strip() and not line.startswith("#")]
    normal = lambda name: re.sub(r"[-_.]+", "-", name).lower()  # noqa: E731
    expect({normal(n) for n in wanted} <= {normal(n) for n in names}, "Companions/nollie-reader/requirements.txt",
           "is missing a package named in requirements.in; regenerate it")

    for item in pins["addons"]["items"]:
        expect((ROOT / "Companions" / item["name"] / "plugin.yaml").is_file(), "Tools/pins.json",
               f"{item['name']} is not an add-on in Companions/")

    sparkle = get("sparkle")
    sparkle_pin = env_file("Tools/sparkle/pin.env")
    expect(sparkle_pin.get("SPARKLE_VERSION") == sparkle["version"] and sparkle_pin.get("SPARKLE_URL") == sparkle["artifact"]["url"]
           and sparkle_pin.get("SPARKLE_SHA256") == sparkle["artifact"]["sha256"]
           and sparkle_pin.get("SPARKLE_BYTES") == str(sparkle["artifact"]["bytes"]),
           "Tools/sparkle/pin.env", "Sparkle differs from pins.json")
    expect(sparkle["version"] in sparkle["artifact"]["url"], "Tools/pins.json", "the Sparkle download is for another version")
    project = read("Nollie.xcodeproj/project.pbxproj")
    versions = set(re.findall(r"NOLLIE_SPARKLE_VERSION = ([^;]+);", project))
    expect(versions == {sparkle["version"]}, "Nollie.xcodeproj/project.pbxproj",
           "NOLLIE_SPARKLE_VERSION differs from pins.json (every Direct configuration must name the pinned Sparkle)")
    expect("Copyright (c) 2006-2013 Andy Matuschak." in read("LICENSE"), "LICENSE", "does not carry Sparkle's notice")
    expect(re.search(r"\| Sparkle[^|]*\| %s\b" % re.escape(sparkle["version"]), notices), "Docs/legal/notices.md",
           f"Sparkle row does not say {sparkle['version']}")
    return problems


# Upstream

def fetch_json(url):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "nollie-check-latest"}
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.loads(response.read())


def version_key(text):
    return [int(part) for part in re.findall(r"\d+", text)]


def github_latest(repo, prefix=""):
    releases = fetch_json(f"https://api.github.com/repos/{repo}/releases?per_page=100")
    names = []
    for release in releases:
        tag = release["tag_name"]
        if release.get("draft") or not tag.startswith(prefix):
            continue
        if release.get("prerelease") and not prefix:
            continue  # A monorepo marks product releases as prereleases only to keep its Latest pointer.
        version = tag[len(prefix):].lstrip("v")
        # Hermes once tagged releases by date (v2026.9.24); those are older than the semantic tags.
        if re.fullmatch(r"\d+\.\d+\.\d+", version) and version_key(version)[0] < 1000:
            names.append(version)
    return max(names, key=version_key) if names else None


def python_latest(series):
    release = fetch_json("https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")
    found = [m.group(1) for asset in release.get("assets", [])
             for m in [re.match(r"cpython-(%s\.\d+)\+\d+-aarch64-apple-darwin-install_only_stripped\.tar\.gz$"
                                % re.escape(series), asset["name"])] if m]
    return (max(found, key=version_key) if found else None), release["tag_name"]


def pypi_latest(name):
    return fetch_json(f"https://pypi.org/pypi/{name}/json")["info"]["version"]


def upstream_rows(pins):
    rows = []
    for item in pins["components"]:
        kind = item["upstream"]["kind"]
        try:
            if kind == "github-release":
                prefix = item["upstream"].get("tagPrefix", "")
                rows.append((item["id"], item["version"], github_latest(item["upstream"]["repo"], prefix), ""))
            elif kind == "uv-python":
                latest, build = python_latest(item["upstream"]["series"])
                rows.append((item["id"], item["version"], latest, f"build {build}; uv must know it before it can be pinned"))
            elif kind == "pypi-lock":
                lock = read("Companions/nollie-reader/requirements.txt")
                for name, version in re.findall(r"^([A-Za-z0-9_.-]+)==(\S+) \\$", lock, re.M):
                    rows.append((f"{item['id']}: {name}", version, pypi_latest(name), ""))
            elif kind == "follows":
                rows.append((item["id"], item["version"], None, f"moves with {item['upstream']['component']}"))
        except Exception as error:  # A failed lookup is reported, never fatal.
            rows.append((item["id"], item["version"], None, f"lookup failed: {type(error).__name__}"))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--local", action="store_true", help="only check the repo against pins.json")
    parser.add_argument("--upstream", action="store_true", help="only report upstream releases")
    parser.add_argument("--strict", action="store_true", help="exit 1 when a pin is behind upstream")
    args = parser.parse_args()
    pins = pinslib.load()
    failed = False
    if not args.upstream:
        problems = local_problems(pins)
        print("Repo against Tools/pins.json: " + ("everything agrees." if not problems else f"{len(problems)} problems"))
        for problem in problems:
            print("  " + problem)
        failed = bool(problems)
    if not args.local:
        rows = upstream_rows(pins)
        behind = 0
        width = max(len(row[0]) for row in rows)
        print("\nComponent".ljust(width + 2) + "  Pinned        Upstream      Status")
        for name, pinned, latest, note in rows:
            if latest is None:
                status = note or "not checked"
            elif version_key(latest) > version_key(pinned):
                status, behind = "behind", behind + 1
            else:
                status = "current"
            if latest is not None and note:
                status += f" ({note})"
            print(f"{name.ljust(width)}  {pinned:<12}  {(latest or '-'):<12}  {status}")
        print(f"\n{behind} pin(s) behind upstream." if behind else "\nNo pin is behind upstream.")
        failed = failed or (args.strict and behind > 0)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
