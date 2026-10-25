"""Shared, file-locked state for every bot on this Mac. Standard library only."""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
from pathlib import Path
import tempfile

STATE_DIR_NAME = "nollie-reader"


def shared_root():
    """One folder under the main Hermes home, shared by every bot's process.

    Profiles live in ``<root>/profiles/<name>``, so the default home is the shared place.
    ``NOLLIE_READER_HOME`` overrides it for tests and temporary homes.
    """
    override = os.environ.get("NOLLIE_READER_HOME", "").strip()
    if override:
        return Path(override).expanduser()
    try:
        from hermes_constants import get_default_hermes_root
        return Path(get_default_hermes_root()) / STATE_DIR_NAME
    except Exception:
        pass
    home = os.environ.get("HERMES_HOME", "").strip()
    if home:
        path = Path(home).expanduser()
        if path.parent.name == "profiles":
            return path.parent.parent / STATE_DIR_NAME
        return path / STATE_DIR_NAME
    return Path.home() / ".hermes" / STATE_DIR_NAME


def ensure_dir(path):
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError(f"refusing a linked state folder: {path}")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


@contextlib.contextmanager
def file_lock(path):
    """Exclusive advisory lock that works across processes (and threads, one fd each)."""
    path = Path(path)
    ensure_dir(path.parent)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def read_json(path, default):
    """A missing or damaged file reads as ``default``; callers then rebuild it."""
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return default
    return value if isinstance(value, type(default)) else default


def atomic_write(path, value):
    path = Path(path)
    ensure_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


@contextlib.contextmanager
def locked_json(path, default):
    """Read, let the caller change, then write back, all under one lock."""
    path = Path(path)
    with file_lock(path.with_name(path.name + ".lock")):
        value = read_json(path, default)
        yield value
        atomic_write(path, value)


def load_settings(root):
    """Optional ``settings.json`` beside the state; anything unreadable means defaults."""
    return read_json(Path(root) / "settings.json", {})
