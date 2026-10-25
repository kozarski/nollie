"""The bots marked Private in Nollie, kept in the main bot's Hermes home.

Hermes has no such setting, so the list is this companion's own small file:
``<main home>/nollie-private-bots.json`` holding ``{"version": 1, "profiles": [...]}``.
nollie-computer reads the same file with its own copy of ``read`` (a test keeps them alike).
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re

from .workflow_core import atomic_write, file_lock, private_identity

FILE_NAME = "nollie-private-bots.json"
LOCK_NAME = "nollie-private-bots.lock"
MAX_PROFILES = 64
MAX_BYTES = 16384
# Hermes's own profile id grammar (hermes_constants.PROFILE_ID_RE).
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")


def carried_over_names():
    """Bots by these names were private in older builds, and they always count as private.

    Before a list is saved they are the list. After that Papertrail, Night shift and the installer
    still add them to whatever was saved.
    """
    return frozenset({"private", "moss"})


def read(home):
    """(names, saved) for the main bot's home. A damaged list raises ValueError: fail closed."""
    path = Path(home) / FILE_NAME
    try:
        if path.is_symlink():
            raise ValueError("the Private list is a link")
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("the Private list is too large")
        document = json.loads(path.read_text())
    except FileNotFoundError:
        return carried_over_names(), False
    except UnicodeDecodeError:
        raise ValueError("the Private list is not readable") from None
    profiles = document.get("profiles") if isinstance(document, dict) and document.get("version") == 1 else None
    if (not isinstance(profiles, list) or len(profiles) > MAX_PROFILES
            or not all(isinstance(name, str) and PROFILE_NAME.match(name) for name in profiles)):
        raise ValueError("the Private list is not valid")
    return frozenset(profiles), True


def names(home):
    return read(home)[0]


class Watch:
    """Whether a bot is private right now, reread only when the list file changes.

    The carried-over names always count, as they do for the Papertrail route. A damaged list
    raises ValueError, so callers fail closed.
    """

    def __init__(self, home, *names):
        self.home = Path(home)
        self.names = tuple(name for name in names if name)
        self._seen = None

    def __call__(self):
        try:
            info = os.lstat(self.home / FILE_NAME)
            signature = (info.st_mtime_ns, info.st_size, info.st_ino)
        except FileNotFoundError:
            signature = None
        if self._seen is None or self._seen[0] != signature:
            private = read(self.home)[0] | carried_over_names()
            self._seen = (signature, any(private_identity(name, private) for name in self.names))
        return self._seen[1]


def excluded(profile, private):
    """True for a bot Nollie never reads: one on the Private list, and always the carried-over names.

    Papertrail, the plugin loader and the installer skip private and moss whatever the list says, so
    the service and the routes do too.
    """
    return private_identity(profile, frozenset(private) | carried_over_names())


def clean(profiles):
    """Lowercased, sorted, unique profile names, or ValueError."""
    if not isinstance(profiles, list) or len(profiles) > MAX_PROFILES:
        raise ValueError(f"Send a list of at most {MAX_PROFILES} bot names.")
    result = set()
    for name in profiles:
        key = name.strip().lower() if isinstance(name, str) else None
        if not key or not PROFILE_NAME.match(key):
            raise ValueError("Each name must be a Hermes profile name.")
        result.add(key)
    return sorted(result)


def save(home, profiles):
    """Replace the whole list atomically and return what was saved."""
    saved = clean(profiles)
    home = Path(home)
    with file_lock(home / LOCK_NAME):
        atomic_write(home / FILE_NAME, {"version": 1, "profiles": saved})
    return saved
