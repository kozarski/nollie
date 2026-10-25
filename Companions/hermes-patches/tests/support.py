"""Import the pinned Hermes with the checked overlay, in an empty temporary home."""
from contextlib import contextmanager, ExitStack
import hashlib
import importlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(os.environ.get("NOLLIE_HERMES_SOURCE", ROOT.parent / "hermes-v0.22.2"))
OVERLAY = ROOT / "Services/Runtime/HermesOverlay"


def checked_files(source=SOURCE):
    manifest = json.loads((OVERLAY / "overlay.json").read_text())
    if not (source / "hermes_cli/plugins.py").is_file():
        raise RuntimeError("Set NOLLIE_HERMES_SOURCE to the pinned Hermes v0.22.2 checkout.")
    git = ["git", "-C", str(source)]
    commit = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    if commit != manifest["hermes"]["commit"] or subprocess.run(
            [*git, "diff", "--quiet", "HEAD", "--"], capture_output=True).returncode:
        raise RuntimeError("The integration fixture needs an unchanged checkout of the pinned Hermes commit.")
    files = {}
    for entry in manifest["files"]:
        original = source / entry["path"]
        before = hashlib.sha256(original.read_bytes()).hexdigest() if original.exists() else None
        if before != entry["before"]:
            raise RuntimeError("Pinned Hermes source changed: " + entry["path"])
        replacement = OVERLAY / "files" / entry["path"]
        data = replacement.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["after"] or len(data) != entry["bytes"]:
            raise RuntimeError("Reviewed overlay changed: " + entry["path"])
        files[entry["path"]] = replacement
    return files


class OverlayImports(importlib.abc.MetaPathFinder):
    def __init__(self, files):
        self.files = files

    def find_spec(self, fullname, path=None, target=None):
        replacement = self.files.get(fullname.replace(".", "/") + ".py")
        if replacement is not None:
            return importlib.util.spec_from_file_location(fullname, replacement)
        return None


def hermes_module(name):
    return importlib.import_module(name)


@contextmanager
def hermes_source():
    files = checked_files()
    names = {p.stem for p in SOURCE.glob("*.py")}
    names.update(p.name for p in SOURCE.iterdir() if p.is_dir() and (p / "__init__.py").exists())
    with tempfile.TemporaryDirectory(prefix="nollie-hermes-test-") as home, ExitStack() as stack:
        stack.enter_context(patch.dict(sys.modules))
        for name in list(sys.modules):
            if name.split(".")[0] in names:
                del sys.modules[name]
        stack.enter_context(patch.dict(os.environ, {
            "HERMES_HOME": home,
            "HERMES_REAL_HOME": home,
            "HERMES_TIMEZONE": "UTC",
            "HERMES_SKIP_STARTUP_REPAIRS": "1",
            "HERMES_SKIP_DEPENDENCY_CHECK": "1",
            "PATH": os.defpath,
        }, clear=True))
        stack.enter_context(patch.object(Path, "home", return_value=Path(home)))
        def expanduser(path):
            if path == "~" or path.startswith("~/"):
                return home + path[1:]
            if path.startswith("~"):
                raise AssertionError("User-home lookups are disabled in fixtures")
            return path
        stack.enter_context(patch.object(os.path, "expanduser", side_effect=expanduser))
        stack.enter_context(patch.object(sys, "dont_write_bytecode", True))
        stack.enter_context(patch.object(sys, "path", [str(SOURCE), *sys.path]))
        stack.enter_context(patch.object(sys, "meta_path", [OverlayImports(files), *sys.meta_path]))
        for name in ("connect", "connect_ex"):
            stack.enter_context(patch.object(socket.socket, name, side_effect=AssertionError("Network is disabled in fixtures")))
        stack.enter_context(patch.object(socket, "create_connection", side_effect=AssertionError("Network is disabled in fixtures")))
        yield Path(home)
