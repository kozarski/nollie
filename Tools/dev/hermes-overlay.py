#!/usr/bin/env python3
"""Build Nollie's reviewed changes to the pinned Hermes source, for the managed Mac setup.

    python3 Tools/dev/hermes-overlay.py            rebuild Services/Runtime/HermesOverlay
    python3 Tools/dev/hermes-overlay.py --source /path/to/hermes-v0.22.2 --check

Without --source it downloads the pinned Hermes archive (Tools/pins.json; checked by size and
SHA-256, cached in build/pins). With --source it checks the local files against the pinned Git
commit, without downloads or writes to that checkout. It applies only the remaining exceptions
in Companions/hermes-patches to temporary copies. The result is files with their SHA-256 before
and after, so the app needs no patch tool: it checks each original, writes the reviewed file and
checks it again. Patch tests and test files stay out. Developer machines only (needs git).
"""
import argparse
import filecmp
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pinslib", HERE / "pinslib.py")
pinslib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinslib)

ROOT = pinslib.ROOT
PATCHES = ["silent-bot-chat.patch", "kanban-machine-prompts.patch", "kanban-timeout-evidence.patch",
           "cron-fail-closed-precheck.patch"]
CACHE = ROOT / "build" / "pins"
REASONS = {
    "silent-bot-chat.patch": "No hook carries trusted cron origin through desktop receipts, final-row storage and resume.",
    "kanban-machine-prompts.patch": "The desktop Board notification submit path has no hook for prompt origin.",
    "kanban-timeout-evidence.patch": "The desktop Board timeout formatter has no text transform hook.",
    "cron-fail-closed-precheck.patch": "The scheduler has no preflight hook before agent creation; tool hooks run too late.",
}


def patch_paths():
    paths = set()
    for name in PATCHES:
        for line in (ROOT / "Companions/hermes-patches" / name).read_text().splitlines():
            if line.startswith(("--- a/", "+++ b/")):
                relative = line[6:]
                if relative.startswith("/") or any(part in ("", ".", "..") for part in relative.split("/")):
                    raise ValueError("Unsafe patch path: " + relative)
                paths.add(relative)
    return paths


def pinned_source(work, source=None):
    hermes = pinslib.component(pinslib.load(), "hermes")
    if source is not None:
        source = Path(source).resolve()
        destination = Path(work) / "pristine"
        git = ["git", "-C", str(source)]
        commit = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        if commit != hermes["commit"]:
            raise ValueError("The local Hermes checkout is not the pinned commit.")
        for relative in sorted(patch_paths() | {"LICENSE"}):
            original = source / relative
            expected = subprocess.run([*git, "show", f"{commit}:{relative}"], capture_output=True)
            if expected.returncode:
                if original.exists() or original.is_symlink():
                    raise ValueError("A new overlay file already exists: " + relative)
                continue
            data = original.read_bytes()
            if original.is_symlink() or pinslib.sha256_bytes(data) != pinslib.sha256_bytes(expected.stdout):
                raise ValueError("Pinned Hermes source changed: " + relative)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        return hermes, destination
    archive = pinslib.fetch(hermes["artifact"], CACHE / f"hermes-{hermes['version']}.tar.gz")
    return hermes, pinslib.safe_extract(archive, Path(work) / "pristine")


def build(output, source=None):
    with tempfile.TemporaryDirectory(prefix="hermes-overlay-") as work:
        hermes, pristine = pinned_source(work, source)
        patched = Path(work) / "patched"
        shutil.copytree(pristine, patched)
        git = ["git", "-c", "core.autocrlf=false", "-C", str(patched)]
        for name in PATCHES:
            subprocess.run([*git, "apply", "--check", str(ROOT / "Companions/hermes-patches" / name)], check=True,
                           capture_output=True)
            subprocess.run([*git, "apply", str(ROOT / "Companions/hermes-patches" / name)], check=True, capture_output=True)
        changed = []
        for path in sorted(p for p in patched.rglob("*") if p.is_file()):
            relative = path.relative_to(patched).as_posix()
            if relative.startswith("tests/") or "/tests/" in relative:
                continue
            original = pristine / relative
            if original.is_file() and filecmp.cmp(original, path, shallow=False):
                continue
            changed.append(relative)
        removed = [p.relative_to(pristine).as_posix() for p in pristine.rglob("*")
                   if p.is_file() and not (patched / p.relative_to(pristine)).exists()]
        if removed:
            sys.exit("A patch removes files, which the overlay does not support: " + ", ".join(removed))
        if output.exists():
            shutil.rmtree(output)
        (output / "files").mkdir(parents=True)
        entries = []
        for relative in changed:
            data = (patched / relative).read_bytes()
            original = pristine / relative
            target = output / "files" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            entries.append({"path": relative,
                            "before": pinslib.sha256_file(original) if original.is_file() else None,
                            "after": pinslib.sha256_bytes(data), "bytes": len(data)})
        shutil.copy2(pristine / "LICENSE", output / "LICENSE-hermes-agent.txt")
        manifest = {"schema": 1,
                    "about": "Remaining Hermes extension gaps. Generated by Tools/dev/hermes-overlay.py; do not edit.",
                    "hermes": {"version": hermes["version"], "commit": hermes["commit"],
                               "archiveSha256": hermes["artifact"]["sha256"]},
                    "patches": PATCHES, "exceptions": REASONS,
                    "files": entries}
        (output / "overlay.json").write_text(json.dumps(manifest, indent=1) + "\n")
    return manifest


def same_tree(a, b):
    left = sorted(p.relative_to(a).as_posix() for p in Path(a).rglob("*") if p.is_file())
    right = sorted(p.relative_to(b).as_posix() for p in Path(b).rglob("*") if p.is_file())
    return left == right and all(filecmp.cmp(Path(a) / n, Path(b) / n, shallow=False) for n in left)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="compare a fresh build with the committed overlay")
    parser.add_argument("--source", type=Path, help="use a local checkout of the pinned commit without downloading")
    args = parser.parse_args()
    if args.check:
        with tempfile.TemporaryDirectory(prefix="hermes-overlay-check-") as temporary:
            build(Path(temporary) / "overlay", args.source)
            if not same_tree(Path(temporary) / "overlay", pinslib.OVERLAY):
                sys.exit("Services/Runtime/HermesOverlay is out of date. Run python3 Tools/dev/hermes-overlay.py.")
        print("The overlay matches the pinned Hermes source and the patches.")
        return
    manifest = build(pinslib.OVERLAY, args.source)
    print(f"Wrote {len(manifest['files'])} files for Hermes {manifest['hermes']['version']}.")
    print(f"Overlay digest (NativeSetupPlan.hermesOverlayDigest): {pinslib.overlay_digest()}")


if __name__ == "__main__":
    main()
