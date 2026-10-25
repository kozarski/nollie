"""Reads the Private list that nollie-workflow saves in the main bot's Hermes home.

The two companions are installed separately, so this is a copy of nollie-workflow's
``private_bots.read``. tests/test_private_bots.py checks that both answer alike.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

FILE_NAME = "nollie-private-bots.json"
MAX_PROFILES = 64
MAX_BYTES = 16384
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")


def carried_over_names():
    """One-time carry-over from older builds, which treated bots by these names as private.

    It applies only until a list is first saved; after that only the saved list counts.
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
