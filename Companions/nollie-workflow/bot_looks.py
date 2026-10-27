"""Each bot's look as the person chose it in Nollie, kept in the main bot's Hermes home.

Hermes has no such setting, and the app used to keep a look only on the device where it was
picked, so a Mac guessed a different character for a helper added on the phone. The choices
now live in this companion's own small file, ``<main home>/nollie-bot-looks.json``:
``{"version": 1, "bots": {"<profile>": {"look": "<id>", "colour": "#RRGGBB"}}}``.
A photo never comes here; it stays on the device that holds it.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

from .workflow_core import atomic_write, file_lock

FILE_NAME = "nollie-bot-looks.json"
LOCK_NAME = "nollie-bot-looks.lock"
MAX_BOTS = 64
MAX_BYTES = 16384
# Hermes's own profile id grammar (hermes_constants.PROFILE_ID_RE).
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
# A character id from Nollie's art package, so new looks need no change here.
LOOK_ID = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")
COLOUR = re.compile(r"#[0-9A-F]{6}\Z")


def _entry(value):
    """One bot's look, tidied, or ValueError. Either part may be missing; an entry with neither is None."""
    if not isinstance(value, dict) or set(value) - {"look", "colour"}:
        raise ValueError("A look has a look id and a colour, nothing else.")
    entry = {}
    look, colour = value.get("look"), value.get("colour")
    if look is not None:
        if not isinstance(look, str) or not LOOK_ID.match(look):
            raise ValueError("The look must be a character id.")
        entry["look"] = look
    if colour is not None:
        colour = colour.upper() if isinstance(colour, str) else None
        if not colour or not COLOUR.match(colour):
            raise ValueError("The colour must be #RRGGBB.")
        entry["colour"] = colour
    return entry or None


def read(home):
    """(bots, saved) for the main bot's home. A damaged file raises ValueError."""
    path = Path(home) / FILE_NAME
    try:
        if path.is_symlink():
            raise ValueError("the looks file is a link")
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("the looks file is too large")
        document = json.loads(path.read_text())
    except FileNotFoundError:
        return {}, False
    except UnicodeDecodeError:
        raise ValueError("the looks file is not readable") from None
    bots = document.get("bots") if isinstance(document, dict) and document.get("version") == 1 else None
    if not isinstance(bots, dict) or len(bots) > MAX_BOTS or not all(
            isinstance(name, str) and PROFILE_NAME.match(name) for name in bots):
        raise ValueError("the looks file is not valid")
    tidy = {name: _entry(value) for name, value in bots.items()}
    return {name: entry for name, entry in tidy.items() if entry}, True


def visible(bots, private):
    """The looks with every private bot's left out."""
    from .private_bots import excluded
    return {name: entry for name, entry in bots.items() if not excluded(name, private)}


def save(home, profile, value):
    """Sets one bot's look (None or an empty look forgets it) and returns all looks.

    One bot at a time, so a device that changes one look never undoes another device's change to another.
    """
    key = profile.strip().lower() if isinstance(profile, str) else ""
    if not PROFILE_NAME.match(key):
        raise ValueError("The bot must be a Hermes profile name.")
    entry = None if value is None else _entry(value)
    home = Path(home)
    with file_lock(home / LOCK_NAME):
        bots, _ = read(home)
        if entry:
            bots[key] = entry
        else:
            bots.pop(key, None)
        if len(bots) > MAX_BOTS:
            raise ValueError(f"Looks are kept for at most {MAX_BOTS} bots.")
        atomic_write(home / FILE_NAME, {"version": 1, "bots": dict(sorted(bots.items()))})
    return bots
