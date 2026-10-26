"""When the Mac was asleep, off, or without Hermes, seen from the service's own ticks.

The service ticks every 15 seconds. Between two ticks of one process, the time the Mac slept is
the difference between a clock that keeps counting through sleep and one that stops: on macOS
``CLOCK_MONOTONIC_RAW`` and ``CLOCK_UPTIME_RAW``. A new process looks at the stamp the last one
left (written at most once a minute): when the Mac started after that stamp it was off, otherwise
Hermes itself was not running. Gaps shorter than three minutes are not kept.

``<main home>/nollie-workflow/sleep.json`` (0600):
``{"version": 1, "seen": {"at": 1792540000, "boot": 1792500000},
"gaps": [{"from": 1792540200, "to": 1792560000, "kind": "asleep"}]}``, the newest 400 within 35 days.
Kinds: ``asleep``, ``off`` (the Mac started again), ``stopped`` (the Mac ran, Hermes didn't).
Nothing else is kept: no apps, no power log, no reasons.
"""
from __future__ import annotations

import json
from pathlib import Path
import time

from .workflow_core import atomic_write, file_lock

FILE_NAME = "sleep.json"
LOCK_NAME = "sleep.lock"
KINDS = frozenset(("asleep", "off", "stopped"))
MIN_GAP = 180
SEEN_EVERY = 60
KEEP_SECONDS = 35 * 86400
LIMIT = 400
MAX_BYTES = 200_000
# A boot more than this after the last stamp means the Mac was turned off or restarted in between.
BOOT_SLACK = 30


def read_clocks():
    """(wall, awake, running): wall time, seconds awake, seconds since boot including sleep.

    ``awake`` and ``running`` are None where the system has no pair of clocks to tell sleep apart.
    """
    wall = time.time()
    awake = running = None
    pair = (getattr(time, "CLOCK_UPTIME_RAW", None), getattr(time, "CLOCK_MONOTONIC_RAW", None))
    if None in pair:
        # Linux: CLOCK_MONOTONIC stops while suspended, CLOCK_BOOTTIME doesn't.
        pair = (getattr(time, "CLOCK_MONOTONIC", None), getattr(time, "CLOCK_BOOTTIME", None))
    if None not in pair:
        try:
            awake, running = time.clock_gettime(pair[0]), time.clock_gettime(pair[1])
        except OSError:
            awake = running = None
    return wall, awake, running


def valid_gap(gap):
    return (isinstance(gap, dict) and gap.get("kind") in KINDS and type(gap.get("from")) is int
            and type(gap.get("to")) is int and gap["to"] > gap["from"])


def read(root):
    """The stored document, with only whole gaps. A missing or damaged file reads as empty."""
    path = Path(root) / FILE_NAME
    try:
        if path.is_symlink() or path.stat().st_size > MAX_BYTES:
            return {"version": 1, "seen": None, "gaps": []}
        document = json.loads(path.read_text())
    except (OSError, ValueError):
        return {"version": 1, "seen": None, "gaps": []}
    if not isinstance(document, dict) or document.get("version") != 1:
        return {"version": 1, "seen": None, "gaps": []}
    seen = document.get("seen")
    if not (isinstance(seen, dict) and type(seen.get("at")) is int
            and (seen.get("boot") is None or type(seen.get("boot")) is int)):
        seen = None
    return {"version": 1, "seen": seen, "gaps": [g for g in document.get("gaps") or [] if valid_gap(g)]}


def gaps(root, start, end):
    """The gaps that overlap ``[start, end)``, cut to it, oldest first."""
    found = []
    for gap in read(root)["gaps"]:
        cut = {"from": max(gap["from"], int(start)), "to": min(gap["to"], int(end)), "kind": gap["kind"]}
        if cut["to"] > cut["from"]:
            found.append(cut)
    return sorted(found, key=lambda g: g["from"])


class SleepWatch:
    """Called once per service tick. Writes only when a gap is found, or once a minute to say it ran."""

    def __init__(self, root, *, clocks=read_clocks):
        self.root = Path(root)
        self.clocks = clocks
        self.last = None
        self.written = None

    def tick(self):
        """The gaps found since the last tick, already saved."""
        wall, awake, running = self.clocks()
        now = int(wall)
        boot = None if running is None else int(wall - running)
        found = []
        if self.last is None:
            seen = read(self.root)["seen"]
            if seen is not None and now - seen["at"] >= MIN_GAP:
                if boot is not None and seen["at"] + BOOT_SLACK < boot <= now:
                    # Off from the last stamp until it started, then on without Hermes until now.
                    found = [{"from": seen["at"], "to": boot, "kind": "off"}, {"from": boot, "to": now, "kind": "stopped"}]
                else:
                    found = [{"from": seen["at"], "to": now, "kind": "stopped"}]
        else:
            last_wall, last_awake, last_running = self.last
            if None not in (awake, running, last_awake, last_running):
                slept = (running - last_running) - (awake - last_awake)
            else:
                # Without both clocks, a tick that came minutes late is the best sign there is.
                slept = wall - last_wall - SEEN_EVERY
            found = [{"from": int(last_wall), "to": int(last_wall + slept), "kind": "asleep"}]
        found = [gap for gap in found if gap["to"] - gap["from"] >= MIN_GAP]
        self.last = (wall, awake, running)
        if found or self.written is None or now - self.written >= SEEN_EVERY:
            self.save(found, now, boot)
            self.written = now
        return found

    def save(self, found, now, boot):
        with file_lock(self.root / LOCK_NAME):
            document = read(self.root)
            kept = document["gaps"] + [gap for gap in found if valid_gap(gap)]
            kept = sorted((g for g in kept if g["to"] >= now - KEEP_SECONDS), key=lambda g: g["from"])[-LIMIT:]
            atomic_write(self.root / FILE_NAME, {"version": 1, "seen": {"at": now, "boot": boot}, "gaps": kept})
