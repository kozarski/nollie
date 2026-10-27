"""The weekly note's records: what one bot did over a week and what left the Mac, as Nollie recorded it.

Counts, names and times only, from what is already kept: the bot's Papertrail day files (places it reached and the
person's answers), its schedules and their runs (Hermes's own cron store and its run ledger, read only), the Board
outcomes the add-on followed, and the bot's connected apps from its config (names and hosts, never commands, keys or
arguments). Nothing here writes a record or keeps a word. The app turns these into the note's sentences; it never
asks a model to.

A week is the 7 Mac-local days ending today, as Papertrail's own window is. Earlier weeks (up to 4, as far back as
Papertrail keeps) are counted only to tell what is new.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta
import math
import os
from pathlib import Path
import re
import sqlite3
import time
from urllib.parse import urlsplit

from . import papertrail as _papertrail

WEEK_DAYS = 7
EARLIER_WEEKS = 4
MAX_PLACES = 60
MAX_SCHEDULES = 60
MAX_APPS = 40
APP_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
# What Hermes's run ledger says of a finished run. "unknown" is a run whose process went away before it said.
RUN_STATES = {"completed": "done", "failed": "failed", "unknown": "unfinished"}
# The Board outcomes the add-on follows (night_shift.BOARD_OUTCOMES), as the note counts them.
BOARD_KINDS = {"completed": "done", "blocked": "stopped", "gave_up": "failed", "block_loop_detected": "failed",
               "escalated": "failed"}
DOOR_PROXY = re.compile(r"http://[^@/\s]+@127\.0\.0\.1:[0-9]{1,5}/?\Z")


def _day(at):
    return datetime.fromtimestamp(at).date()


def _midnight(day):
    return _papertrail._midnight(day)


def _epoch(value):
    """A time Hermes keeps as an ISO string or a number, as seconds; None when it can't be read."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if math.isfinite(value) and value > 0 else None
    if isinstance(value, str) and value.strip():
        try:
            return datetime.fromisoformat(value.strip().replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


# Places and answers, from Papertrail ---------------------------------------------------------------------------

def _place_key(call):
    """Where one Papertrail line went, as the note groups it; None for a line that stayed on this Mac."""
    if call["route"] == "mac" or call["source"] == "approval":
        return None
    source = call["source"]
    if source == "door":
        return ("door", call["kind"], call["host"] or "")
    if source in ("model", "helper"):
        return ("model", call["provider"] or "", call["host"] or "")
    if source == "away":
        return ("icloud", "", "")
    return None


def _tool_places(call):
    """A tool line's places and how much each got: searches by service, pages, pictures, payments by site."""
    if call["source"] != "tool" or call["route"] == "mac":
        return []
    found = []
    if call["searches"]:
        found.append((("search", call["provider"] or "", ""), call["searches"]))
    if call["pages"]:
        found.append((("pages", "", ""), call["pages"]))
    if call["images"]:
        found.append((("pictures", "", ""), call["images"]))
    if call["paid"] and call["host"]:
        found.append((("paid", "", call["host"]), call["paid"]))
    return found


def _lines(home, first, today):
    """Every Papertrail line of the bot from ``first`` to today, and the first day kept."""
    root = Path(home) / "nollie-workflow" / "papertrail"
    calls, oldest = [], None
    if not root.is_dir() or root.is_symlink():
        return calls, oldest
    for path in sorted(root.iterdir()):
        match = _papertrail.DAY_FILE.match(path.name)
        if not match or path.is_symlink() or not path.is_file():
            continue
        try:
            day = date.fromisoformat(match.group(1))
        except ValueError:
            continue
        oldest = day if oldest is None or day < oldest else oldest
        if first <= day <= today:
            calls.extend(_papertrail._calls(path, _midnight(first)))
    return calls, oldest


def places_and_answers(home, *, now, provider_name=None):
    """This week's places (grouped, counted, each with when it was first seen in all that is kept), the person's
    answers this week, and their answers in each earlier full week Papertrail kept."""
    today = _day(now)
    week_first = today - timedelta(days=WEEK_DAYS - 1)
    since = _midnight(week_first)
    first = today - timedelta(days=_papertrail.KEEP_DAYS - 1)
    calls, oldest = _lines(home, first, today)
    seen_first, counts = {}, {}
    answers = {"once": 0, "session": 0, "always": 0, "deny": 0}
    asks = {}
    earlier = [0] * EARLIER_WEEKS
    for call in calls:
        at = call["at"]
        found = [(key, 1) for key in [_place_key(call)] if key] + _tool_places(call)
        for key, amount in found:
            seen_first[key] = min(seen_first.get(key, at), at)
            if at >= since:
                counts[key] = counts.get(key, 0) + amount
        if call["source"] == "approval":
            if at >= since:
                answers[call["choice"]] += 1
                if call["ask"] in _papertrail.ASK_KINDS:
                    asks[call["ask"]] = asks.get(call["ask"], 0) + 1
            else:
                back = (week_first - _day(at)).days
                index = (back - 1) // WEEK_DAYS if back >= 1 else None
                if index is not None and 0 <= index < EARLIER_WEEKS:
                    earlier[index] += 1
    # Only the earlier weeks Papertrail kept from their first day count as a week.
    full = 0
    if oldest is not None:
        while full < EARLIER_WEEKS and oldest <= week_first - timedelta(days=WEEK_DAYS * (full + 1)):
            full += 1
    names = {}

    def label(provider):
        if provider not in names:
            try:
                names[provider] = (provider_name or _papertrail._hermes_provider_name)(provider)
            except Exception:
                names[provider] = None
        return names[provider]

    places = []
    for key, count in counts.items():
        kind, name, host = key
        place = {"kind": kind, "count": count, "first_at": int(seen_first[key])}
        if kind == "door":
            place.update(kind=name, host=host)
        elif kind == "model":
            place.update(kind="model", provider=name or None, label=label(name) if name else None, host=host or None)
        elif kind == "search":
            place.update(service=name or None)
        elif kind == "paid":
            place.update(host=host)
        places.append(place)
    places.sort(key=lambda p: (-p["count"], p["kind"], str(p.get("host") or p.get("provider") or p.get("service") or "")))
    return {
        "since": since,
        "recording_since": _midnight(oldest) if oldest else None,
        "places": places[:MAX_PLACES],
        "places_more": max(0, len(places) - MAX_PLACES),
        "answers": answers,
        "asks": dict(sorted(asks.items())),
        "earlier_answers": earlier[:full],
    }


# Schedules and their runs ---------------------------------------------------------------------------------------

def runs(ledger, since):
    """Each job's finished runs since ``since`` from Hermes's run ledger (``cron/executions.db``), opened read only.
    None when it can't be read, so the note says nothing rather than "no runs"."""
    path = Path(ledger)
    if not path.is_file() or path.is_symlink():
        return {} if not path.exists() else None
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1.0)
    except sqlite3.Error:
        return None
    try:
        rows = connection.execute(
            "SELECT job_id, status, claimed_at, finished_at FROM executions"
            " WHERE status IN ('completed', 'failed', 'unknown')").fetchall()
    except sqlite3.Error:
        return None
    finally:
        connection.close()
    found = {}
    for job_id, status, claimed, finished in rows:
        at = _epoch(finished) or _epoch(claimed)
        if not isinstance(job_id, str) or at is None or at < since:
            continue
        tally = found.setdefault(job_id, {"done": 0, "failed": 0, "unfinished": 0})
        tally[RUN_STATES[status]] += 1
    return found


def schedules(jobs, ran, *, name=lambda text: text):
    """The bot's schedules: id, the name the person gave it, when it was made, whether it is paused, and its runs
    this week (None when the ledger couldn't be read)."""
    found = []
    for job in jobs:
        if not isinstance(job, dict) or not isinstance(job.get("id"), str) or not job["id"]:
            continue
        title = job.get("name") if isinstance(job.get("name"), str) else ""
        state = job.get("state") if isinstance(job.get("state"), str) else ""
        found.append({
            "id": job["id"][:64],
            "name": name(title.strip()) or None,
            "created_at": int(_epoch(job.get("created_at")) or 0) or None,
            "paused": job.get("enabled") is False or state == "paused",
            "finished": state in ("completed", "finished", "done"),
            "runs": None if ran is None else ran.get(job["id"], {"done": 0, "failed": 0, "unfinished": 0}),
        })
    found.sort(key=lambda job: (-(sum(job["runs"].values()) if job["runs"] else 0), job["name"] or "", job["id"]))
    return found[:MAX_SCHEDULES]


def board(outcomes, bot, since):
    """Board tasks this bot finished, stopped on or gave up this week, as the add-on followed them."""
    found = {"done": 0, "stopped": 0, "failed": 0}
    for item in outcomes:
        if item.get("assignee") == bot and item.get("at", 0) >= since and item.get("outcome") in BOARD_KINDS:
            found[BOARD_KINDS[item["outcome"]]] += 1
    return found


# Connected apps, web search and the filter ----------------------------------------------------------------------

def apps(config):
    """The bot's connected apps (its MCP servers): the name, whether it is on, and the host of a URL one. Never a
    command, an argument, a header or a key."""
    servers = config.get("mcp_servers") if isinstance(config, dict) else None
    found = []
    for name, server in (servers.items() if isinstance(servers, dict) else ()):
        if not isinstance(name, str) or not APP_NAME.match(name) or not isinstance(server, dict):
            continue
        on = server.get("enabled", True)
        on = on if isinstance(on, bool) else str(on).strip().lower() not in ("false", "0", "no", "off")
        url = server.get("url") if isinstance(server.get("url"), str) else ""
        try:
            host = urlsplit(url).hostname if url else None
        except ValueError:
            host = None
        found.append({"name": name, "on": on, "host": host})
    found.sort(key=lambda app: app["name"])
    return found[:MAX_APPS]


def web(config):
    """Whether the bot may search and read the web (Hermes's ``web`` tools), and its search service."""
    agent = config.get("agent") if isinstance(config, dict) else None
    disabled = agent.get("disabled_toolsets") if isinstance(agent, dict) else None
    off = isinstance(disabled, list) and "web" in disabled
    return {"on": not off, "service": _papertrail._search_backend(config) or None}


def filter_state(environ=None):
    """Papertrail's network filter as Nollie Runtime runs it: ``on``, ``off``, or ``none`` when Hermes was not
    started through Nollie's door (a Hermes run by hand has no door, so only the add-on's own lines are kept)."""
    environ = os.environ if environ is None else environ
    proxy = environ.get("HTTPS_PROXY") or environ.get("https_proxy") or ""
    if not DOOR_PROXY.match(proxy):
        return "none"
    path = environ.get("NOLLIE_NETWORK_FILTER") or ""
    if not path:
        return "off"
    try:
        target = Path(path)
        if target.is_symlink() or not target.is_file() or target.stat().st_size > 4096:
            return "off"
        import json
        switch = json.loads(target.read_text())
    except (OSError, ValueError):
        return "off"
    return "on" if isinstance(switch, dict) and switch.get("version") == 1 and switch.get("on") is True else "off"


def read(home, bot, *, now=None, jobs=(), outcomes=(), config=None, ledger=None, name=lambda text: text,
         provider_name=None, environ=None):
    """The weekly note's records for one bot home. ``jobs`` are its schedules as Hermes lists them, ``outcomes`` the
    Board outcomes the add-on followed, ``config`` its config, ``ledger`` its run ledger's path, ``name`` cleans a
    schedule's name (and returns "" to leave it out)."""
    now = time.time() if now is None else now
    found = places_and_answers(home, now=now, provider_name=provider_name)
    week = _papertrail.read(home, bot, WEEK_DAYS, now=now, provider_name=provider_name or (lambda _: None),
                            limit=None)
    entries = week["entries"]
    online = sum(entry["route"] == "online" for entry in entries)
    ran = runs(ledger if ledger is not None else Path(home) / "cron" / "executions.db", found["since"])
    config = config if isinstance(config, dict) else {}
    found.update({
        "bot": bot,
        "days": WEEK_DAYS,
        "now": int(now),
        "replies": {"stayed": week["stayed"]["window"], "left": week["left"]["window"], "online": online},
        "schedules": schedules(jobs, ran, name=name),
        "runs_kept": ran is not None,
        "board": board(outcomes, bot, found["since"]),
        "apps": apps(config),
        "web": web(config),
        "filter": filter_state(environ),
    })
    return found


# The switches a note's tap may change ---------------------------------------------------------------------------

class ConfigFile:
    """One bot's config, read and written through Hermes's own loader and saver under that bot's home, as Hermes's
    `hermes mcp enable` does."""

    def __init__(self, home):
        self.home = Path(home)

    def _scoped(self, work):
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override
        token = set_hermes_home_override(self.home)
        try:
            return work()
        finally:
            reset_hermes_home_override(token)

    def load(self):
        def work():
            from hermes_cli.config import load_config
            return load_config()
        return self._scoped(work)

    def save(self, config):
        def work():
            from hermes_cli.config import save_config
            save_config(config)
        self._scoped(work)


class NoSuchSwitch(LookupError):
    pass


def set_switch(config_file, kind, name, on):
    """Turns one of a bot's connected apps (``kind`` ``app``) or its web tools (``web``) on or off, and answers with
    what the config says afterwards. Turning off is always allowed; nothing is removed."""
    config = config_file.load()
    if not isinstance(config, dict):
        raise NoSuchSwitch(kind)
    if kind == "app":
        servers = config.get("mcp_servers")
        server = servers.get(name) if isinstance(servers, dict) else None
        if not isinstance(server, dict):
            raise NoSuchSwitch(name)
        server["enabled"] = bool(on)
    elif kind == "web":
        agent = config.setdefault("agent", {})
        if not isinstance(agent, dict):
            raise NoSuchSwitch(kind)
        disabled = [item for item in (agent.get("disabled_toolsets") or []) if isinstance(item, str) and item != "web"]
        agent["disabled_toolsets"] = disabled if on else disabled + ["web"]
    else:
        raise NoSuchSwitch(kind)
    config_file.save(config)
    after = config_file.load()
    if kind == "app":
        shown = next((app for app in apps(after) if app["name"] == name), None)
        return {"kind": "app", "name": name, "on": bool(shown and shown["on"])}
    return {"kind": "web", "name": None, "on": web(after)["on"]}
