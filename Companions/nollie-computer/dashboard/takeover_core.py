"""Take over and hand back a bot's computer through Hermes's own desktop lease.

Hermes keeps one lease per bot at ``<home>/bot-desktop/lease.json`` (``tools/bot_desktop/lease.py``).
While a person holds it, Hermes's own ``computer_use`` and browser tools refuse every action, and
any action admitted before the change is voided by its epoch check. Cua computers reached through
the ``cua`` MCP server do not read that file, so this companion's ``pre_tool_call`` hook refuses
their tools while Nollie holds the lease (``blocked_message``).

Every change goes through the lease module's own locked transition, so it is atomic with Hermes's
readers and always increases the epoch. Take over remembers who held the lease before; Hand back
restores exactly that holder, but only while the lease is still the one Take over wrote; a bot
that had no lease file gets none back, so it never ends with more than it had. The companion
never changes config, tool lists, approvals or the Mac's own Nollie Computer.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import time

VIEWER = "nollie-watch"
REASON = "A person took over in Nollie"
RECORD = "nollie-takeover.json"
# The viewer the app's System control switch writes when it is off.
SYSTEM_CONTROL_OFF = "nollie-app"
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
RECORD_MAX = 4096
VIEWER_NAME = re.compile(r"[A-Za-z0-9_.:-]{1,80}\Z")


class ControlUnavailable(Exception):
    """An expected failure with nothing private attached."""


def lease_module():
    from tools.bot_desktop import lease
    if not all(callable(getattr(lease, name, None)) for name in ("_transition", "get", "_locked", "_read")):
        raise ControlUnavailable()
    return lease


def profile_home(profile):
    from hermes_cli.profiles import get_profile_dir, profile_exists
    if not profile_exists(profile):
        raise ControlUnavailable()
    return Path(get_profile_dir(profile))


def control_of(lease):
    """Who has the computer, as the app shows it. Never exposes a viewer id."""
    if lease.holder == "human" and lease.viewer_id == VIEWER:
        return "you"
    if lease.holder == "human" and lease.viewer_id not in (SYSTEM_CONTROL_OFF,):
        return "someone"
    return "helper"


def _record_path(home):
    return Path(home) / "bot-desktop" / RECORD


def _lease_path(home):
    return Path(home) / "bot-desktop" / "lease.json"


def read_record(home):
    path = _record_path(home)
    try:
        if path.is_symlink() or path.stat().st_size > RECORD_MAX:
            return None
        document = json.loads(path.read_text())
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(document, dict) or document.get("version") != 1 or not isinstance(document.get("epoch"), int):
        return None
    prior = document.get("prior")
    if not isinstance(prior, dict) or prior.get("holder") not in ("agent", "human"):
        return None
    viewer = prior.get("viewer_id")
    if prior["holder"] == "human" and not (isinstance(viewer, str) and VIEWER_NAME.fullmatch(viewer)):
        return None
    reason = prior.get("reason") if isinstance(prior.get("reason"), str) else ""
    return {"epoch": document["epoch"], "holder": prior["holder"],
            "viewer_id": viewer if prior["holder"] == "human" else None, "reason": reason[:200],
            # Only an explicit true counts: an older or damaged record never removes a lease.
            "absent": prior["holder"] == "agent" and prior.get("absent") is True}


def _write_record(home, epoch, prior):
    path = _record_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ControlUnavailable()
    temporary = path.with_name(RECORD + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(json.dumps({"version": 1, "epoch": epoch, "prior": prior, "at": time.time()}))
    os.replace(temporary, path)


def _remove_record(home):
    try:
        _record_path(home).unlink()
    except FileNotFoundError:
        pass


class ControlService:
    """``take_over`` and ``hand_back`` for one bot; both are safe to repeat."""

    def __init__(self, lease_loader=lease_module, home_for=profile_home, private_reader=None):
        self.lease_loader, self.home_for = lease_loader, home_for
        self.private_reader = private_reader

    def _refused(self, profile):
        if not isinstance(profile, str) or not PROFILE_NAME.fullmatch(profile):
            return True
        try:
            return profile in self.private_reader()
        except Exception:
            return True

    def _setup(self, profile):
        if self._refused(profile):
            raise ControlUnavailable()
        return self.lease_loader(), self.home_for(profile)

    def control(self, profile):
        """Who holds the computer now, or None when it can't be read."""
        try:
            lease, home = self._setup(profile)
            return control_of(lease.get(profile_key=str(home)))
        except Exception:
            return None

    def take_over(self, profile):
        lease, home = self._setup(profile)
        answer = {}

        def mutate(current):
            if current.holder == "human" and current.viewer_id == VIEWER:
                answer["control"] = "you"
                return False
            if current.holder == "human" and current.viewer_id != SYSTEM_CONTROL_OFF:
                # Another person, or a lease Hermes could not read: never evict them.
                answer["control"] = "someone"
                return False
            # Under the lease's lock: whether a file was there at all is part of what comes back.
            prior = ({"holder": "agent", "absent": not _lease_path(home).exists()} if current.holder == "agent" else
                     {"holder": "human", "viewer_id": current.viewer_id, "reason": current.reason or ""})
            # The record comes first: a lease held by Nollie always has a way back.
            _write_record(home, current.epoch + 1, prior)
            current.holder, current.viewer_id, current.since, current.reason = "human", VIEWER, time.time(), REASON
            answer["control"] = "you"
            return True

        lease._transition(str(home), mutate)
        return {"control": answer.get("control", "helper")}

    def _remove_if_ours(self, lease, home, record):
        """Hand back for a bot that had no lease file: remove it, under the same lock and checks."""
        path = _lease_path(home)
        with lease._locked(path):
            current = lease._read(path)
            if not (current.holder == "human" and current.viewer_id == VIEWER and record["epoch"] == current.epoch):
                return None
            path.unlink()
        try:
            # Wake this process's own waiters and listeners, as Hermes does after a change.
            with lease._lock:
                lease._lock.notify_all()
            lease._notify(lease.hermes_home_key(str(home)), lease.Lease())
        except Exception:
            pass
        return {"control": "helper"}

    def hand_back(self, profile):
        lease, home = self._setup(profile)
        record = read_record(home)
        if record is not None and record["absent"]:
            restored = self._remove_if_ours(lease, home, record)
            if restored is not None:
                _remove_record(home)
                return restored
        answer = {}

        def mutate(current):
            if not (current.holder == "human" and current.viewer_id == VIEWER):
                answer["control"] = control_of(current)
                return False
            if record is None or record["epoch"] != current.epoch:
                # No trustworthy way back: leave the helper paused for its Mac, never grant more.
                current.viewer_id, current.reason = SYSTEM_CONTROL_OFF, "System control is off in the Nollie app"
            elif record["holder"] == "human":
                current.viewer_id, current.reason = record["viewer_id"], record["reason"]
            else:
                current.holder, current.viewer_id, current.reason = "agent", None, ""
            current.since = time.time()
            answer["control"] = control_of(current)
            return True

        lease._transition(str(home), mutate)
        _remove_record(home)
        return {"control": answer.get("control", "helper")}


def held_by_nollie(lease=None):
    """Whether Nollie holds the current bot's lease, read fresh for every tool call."""
    lease = lease or lease_module()
    current = lease.get()
    return current.holder == "human" and current.viewer_id == VIEWER


def cua_call(tool_name, args):
    """Whether a tool call reaches a Cua computer, directly or through Hermes's one-tool bridge."""
    if isinstance(tool_name, str) and tool_name.startswith("mcp__cua__"):
        return True
    if tool_name != "tool_call" or not isinstance(args, dict):
        return False
    entries = args.get("calls", [{"name": args.get("name")}])
    if isinstance(entries, str):
        try:
            entries = json.loads(entries)
        except ValueError:
            return True
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list):
        return True
    return any(not isinstance(entry, dict) or not isinstance(entry.get("name"), str)
               or entry["name"].startswith("mcp__cua__") for entry in entries)


BLOCKED = ("A person has taken over this computer in Nollie and is using it now. Don't try again "
           "until they hand it back. Tell them what you were about to do and wait.")


def blocked_message(tool_name, args, holds=held_by_nollie):
    """The refusal for a Cua tool while Nollie holds the lease, else None."""
    if not cua_call(tool_name, args):
        return None
    try:
        return BLOCKED if holds() else None
    except Exception:
        # No lease module means Take over could never have happened either.
        return None
