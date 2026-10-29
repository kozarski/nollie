"""The weekly note's settings for all of the person's devices, kept in the main bot's Hermes home beside the bots'
looks: which helpers are muted, the note's day, and when the Mac last said it sends the note itself.

``<main home>/nollie-weekly.json``: ``{"version": 1, "muted": ["career"], "note": {"on": true, "weekday": 1},
"live_at": 1793034000}``. Names and switches only. A private bot is never kept here.
"""
from __future__ import annotations

import json
from pathlib import Path
import time

from .bot_looks import PROFILE_NAME
from .workflow_core import atomic_write, file_lock

FILE_NAME = "nollie-weekly.json"
LOCK_NAME = "nollie-weekly.lock"
MAX_BOTS = 64
MAX_BYTES = 8192
DEFAULT_NOTE = {"on": True, "weekday": 1}


def _note(value):
    if not isinstance(value, dict) or not isinstance(value.get("on"), bool):
        return dict(DEFAULT_NOTE)
    weekday = value.get("weekday")
    if isinstance(weekday, bool) or not isinstance(weekday, int) or not 1 <= weekday <= 7:
        weekday = DEFAULT_NOTE["weekday"]
    return {"on": value["on"], "weekday": weekday}


def read(home):
    """(settings, saved). A damaged file raises ValueError; a missing one is the defaults."""
    path = Path(home) / FILE_NAME
    try:
        if path.is_symlink():
            raise ValueError("the weekly file is a link")
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("the weekly file is too large")
        document = json.loads(path.read_text())
    except FileNotFoundError:
        return {"muted": [], "note": dict(DEFAULT_NOTE), "live_at": None}, False
    except UnicodeDecodeError:
        raise ValueError("the weekly file is not readable") from None
    if not isinstance(document, dict) or document.get("version") != 1:
        raise ValueError("the weekly file is not valid")
    muted = document.get("muted")
    if not isinstance(muted, list) or len(muted) > MAX_BOTS or not all(
            isinstance(name, str) and PROFILE_NAME.match(name) for name in muted):
        raise ValueError("the weekly file is not valid")
    live = document.get("live_at")
    live = live if isinstance(live, int) and not isinstance(live, bool) and live > 0 else None
    return {"muted": sorted(set(muted)), "note": _note(document.get("note")), "live_at": live}, True


def visible(settings, private):
    """The settings with every private bot left out."""
    from .private_bots import excluded
    return dict(settings, muted=[name for name in settings["muted"] if not excluded(name, private)])


def _save(home, change):
    home = Path(home)
    with file_lock(home / LOCK_NAME):
        settings, _ = read(home)
        change(settings)
        if len(settings["muted"]) > MAX_BOTS:
            raise ValueError(f"Mute is kept for at most {MAX_BOTS} helpers.")
        atomic_write(home / FILE_NAME, {"version": 1, "muted": sorted(set(settings["muted"])),
                                        "note": settings["note"], "live_at": settings["live_at"]})
    return settings


def mute(home, profile, muted):
    """Mutes or unmutes one helper, and returns all settings. One helper at a time, so devices never undo each
    other's changes to other helpers."""
    key = profile.strip().lower() if isinstance(profile, str) else ""
    if not PROFILE_NAME.match(key) or not isinstance(muted, bool):
        raise ValueError("Send a helper's Hermes profile name and muted true or false.")

    def change(settings):
        names = set(settings["muted"])
        if muted:
            names.add(key)
        else:
            names.discard(key)
        settings["muted"] = sorted(names)
    return _save(home, change)


def set_note(home, on, weekday):
    """The note on or off, and its day (1 is Sunday, as Apple's calendars count)."""
    if not isinstance(on, bool) or isinstance(weekday, bool) or not isinstance(weekday, int) or not 1 <= weekday <= 7:
        raise ValueError("Send on true or false and a weekday from 1 to 7.")

    def change(settings):
        settings["note"] = {"on": on, "weekday": weekday}
    return _save(home, change)


def mark_live(home, now=None):
    """The Mac's alert helper says it builds and sends the note itself, with the week's counts, at send time."""
    def change(settings):
        settings["live_at"] = int(time.time() if now is None else now)
    return _save(home, change)
