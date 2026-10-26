"""Calendar, Reminders and Contacts on the person's Mac, for the helpers they turned them on for.

The data stays in the Mac's own apps. Nollie on the Mac reads and changes it with Apple's own
frameworks, so macOS asks about Nollie by name, and only for a helper whose switch is on in Bot
settings (all three start off). This add-on keeps three small things in the main bot's home, under
``nollie-workflow/apple-data/`` (folders 0700, files 0600):

- ``bots.json``: which of Calendar, Reminders and Contacts each helper may use.
- ``mac.json``: what the Mac last said about its own permissions, so the iPhone can show it.
- ``requests/<id>.json``: one tool call while it is open. A read's answer stays only until the tool
  has picked it up, then the file is deleted.

A read goes to the Mac and back. A change never happens on the helper's say-so: the Mac first words
it ("Add “Dentist” on Tue 4 Nov, 10:00 to Home calendar?") without making it, this tool asks the
person through Hermes's own approval gate with exactly those words, and only after a yes does the Mac
make the change it worded. That holds whatever the Ask first switch says, and a run nobody can answer
(a schedule, Board work) is held instead, never done.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import re
import secrets
import time

from .workflow_core import atomic_write, file_lock

FOLDER = "apple-data"
AREAS = ("calendar", "reminders", "contacts")
AREA_NAMES = {"calendar": "Calendar", "reminders": "Reminders", "contacts": "Contacts"}
TOOLSETS = {"calendar": "nollie_calendar", "reminders": "nollie_reminders", "contacts": "nollie_contacts"}
ACCESS = ("allowed", "denied", "not_asked", "unavailable")

READS = {"calendar_events": "calendar", "calendar_search": "calendar", "reminder_lists": "reminders",
         "reminders_open": "reminders", "contacts_search": "contacts"}
WRITES = {"calendar_add_event": "calendar", "calendar_change_event": "calendar", "calendar_delete_event": "calendar",
          "reminder_add": "reminders", "reminder_complete": "reminders", "reminder_delete": "reminders",
          "contact_add": "contacts", "contact_change": "contacts"}
TOOLS = {**READS, **WRITES}

# waiting: for the Mac. prepared: a change the Mac has worded, waiting for the person. approved: the
# person said yes, waiting for the Mac to make it. done: the Mac's answer is in.
STATES = ("waiting", "prepared", "approved", "done")
REQUEST_ID = re.compile(r"[0-9a-f]{32}\Z")
# Ask first's own rule prefix, so the app shows its card: plugin_rule:nollie-ask-first:<area>:<id>.
RULE_PREFIX = "nollie-ask-first:"
MAC_WAIT = 20.0      # for the Mac to answer a read or word a change
APPLY_WAIT = 30.0    # for the Mac to make a change after the yes
POLL = 0.25
REQUEST_LIFETIME = 600
MAX_RESULT = 256 * 1024
CARD_LIMIT = 1200

# Night shift and Ask first's guard recognise a hold by this start (ask_first.HELD).
HELD = "Held for the person's yes"

MESSAGES = {
    "private": "Calendar, Reminders and Contacts aren't available to this bot.",
    "off": "{name} is off for this helper. The person can turn it on in Bot settings, Apps.",
    "unattended": HELD + (": Nollie asks the person before changing their calendar, reminders or contacts, and "
                          "nobody can answer in this run. It was not done. Say in your report that it is waiting "
                          "for them: {card}"),
    "bypassed": ("Not done: Nollie asks the person before changing their calendar, reminders or contacts, and "
                 "approvals are switched off for this bot, so nobody could be asked. Tell the person what you "
                 "wanted to do: {card}"),
    "no_mac": "Nollie on the Mac didn't answer. It may be closed. Ask the person to open Nollie on their Mac.",
    "busy": "That couldn't be started right now. Try again in a moment.",
    "declined": "The person said no, so nothing was changed. Don't try again unless they ask.",
    "no_answer": "Nobody answered, so nothing was changed. Don't try again unless the person asks.",
    "unsure": "Nollie on the Mac didn't confirm the change. It may or may not have been made: look before trying again.",
}

# Arguments each tool takes: (kind, longest). Anything else is dropped before the Mac sees it.
_TEXT, _LONG, _FLAG, _LIST = ("text", 300), ("text", 2000), ("flag", 0), ("list", 20)
ARGUMENTS = {
    "calendar_events": {"start": _TEXT, "end": _TEXT, "calendar": _TEXT},
    "calendar_search": {"text": _TEXT, "start": _TEXT, "end": _TEXT},
    "calendar_add_event": {"title": _TEXT, "start": _TEXT, "end": _TEXT, "all_day": _FLAG, "calendar": _TEXT,
                           "location": _TEXT, "notes": _LONG},
    "calendar_change_event": {"event_id": _TEXT, "title": _TEXT, "start": _TEXT, "end": _TEXT, "all_day": _FLAG,
                              "calendar": _TEXT, "location": _TEXT, "notes": _LONG},
    "calendar_delete_event": {"event_id": _TEXT},
    "reminder_lists": {},
    "reminders_open": {"list": _TEXT, "due_before": _TEXT},
    "reminder_add": {"title": _TEXT, "list": _TEXT, "due": _TEXT, "notes": _LONG},
    "reminder_complete": {"reminder_id": _TEXT},
    "reminder_delete": {"reminder_id": _TEXT},
    "contacts_search": {"name": _TEXT},
    "contact_add": {"given_name": _TEXT, "family_name": _TEXT, "phone": _TEXT, "email": _TEXT, "birthday": _TEXT},
    "contact_change": {"contact_id": _TEXT, "given_name": _TEXT, "family_name": _TEXT, "add_phone": _TEXT,
                       "add_email": _TEXT, "birthday": _TEXT},
}
REQUIRED = {"calendar_search": ("text",), "calendar_add_event": ("title", "start"),
            "calendar_change_event": ("event_id",), "calendar_delete_event": ("event_id",),
            "reminder_add": ("title",), "reminder_complete": ("reminder_id",), "reminder_delete": ("reminder_id",),
            "contacts_search": ("name",), "contact_add": ("given_name",), "contact_change": ("contact_id",)}


class Conflict(Exception):
    pass


def clean(tool, args):
    """Only the arguments the tool takes, as plain bounded values. Raises ValueError for a missing one."""
    args = args if isinstance(args, dict) else {}
    cleaned = {}
    for key, (kind, longest) in ARGUMENTS[tool].items():
        value = args.get(key)
        if value is None:
            continue
        if kind == "flag":
            if isinstance(value, bool):
                cleaned[key] = value
        elif isinstance(value, (str, int, float)) and not isinstance(value, bool):
            text = " ".join(str(value).split()) if key != "notes" else str(value).strip()
            if text:
                cleaned[key] = text[:longest]
    missing = [key for key in REQUIRED.get(tool, ()) if key not in cleaned]
    if missing:
        raise ValueError(f"Send {' and '.join(missing)}.")
    return cleaned


class Store:
    """Shared by the tool (in the gateway or dashboard) and the routes, through files under one lock."""

    def __init__(self, main_home, clock=time.time):
        self.root = Path(main_home) / "nollie-workflow" / FOLDER
        self.clock = clock

    @contextlib.contextmanager
    def _locked(self):
        for path in (self.root.parent, self.root, self.root / "requests"):
            if path.is_symlink():
                raise ValueError("an apple-data folder is a link")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with file_lock(self.root / "apple-data.lock"):
            yield

    def _document(self, name, limit=64 * 1024):
        path = self.root / name
        try:
            if path.is_symlink() or path.stat().st_size > limit:
                raise ValueError(f"{name} is not readable")
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return None
        except UnicodeDecodeError:
            raise ValueError(f"{name} is not readable") from None
        if not isinstance(document, dict) or document.get("version") != 1:
            raise ValueError(f"{name} is not valid")
        return document

    # Which helpers may use what ---------------------------------------------------------

    def bots(self):
        """{bot: [areas]} for every helper with at least one switch on. A damaged file raises: fail closed."""
        document = self._document("bots.json")
        if document is None:
            return {}
        bots = document.get("bots")
        if not isinstance(bots, dict) or not all(
                isinstance(k, str) and isinstance(v, list) and all(a in AREAS for a in v) for k, v in bots.items()):
            raise ValueError("bots.json is not valid")
        return {bot: sorted(set(areas)) for bot, areas in bots.items() if areas}

    def enabled(self, bot, area):
        try:
            return area in self.bots().get(bot, [])
        except (OSError, ValueError):
            return False

    def set_bot(self, bot, areas):
        if not isinstance(areas, list) or not all(a in AREAS for a in areas):
            raise ValueError("Choose from calendar, reminders and contacts.")
        with self._locked():
            bots = self.bots()
            if areas:
                bots[bot] = sorted(set(areas))
            else:
                bots.pop(bot, None)
            atomic_write(self.root / "bots.json", {"version": 1, "bots": bots})
        return sorted(set(areas))

    def mac(self):
        """What the Mac last said about its permissions, or None before it has."""
        try:
            document = self._document("mac.json")
        except (OSError, ValueError):
            return None
        access = document.get("access") if document else None
        if not isinstance(access, dict):
            return None
        return {area: access.get(area) if access.get(area) in ACCESS else "not_asked" for area in AREAS}

    def save_mac(self, access):
        if not isinstance(access, dict) or set(access) - set(AREAS) or not all(v in ACCESS for v in access.values()):
            raise ValueError("Send each of calendar, reminders and contacts as allowed, denied or not_asked.")
        cleaned = {area: access.get(area, "not_asked") for area in AREAS}
        with self._locked():
            atomic_write(self.root / "mac.json", {"version": 1, "at": int(self.clock()), "access": cleaned})
        return cleaned

    # Requests ---------------------------------------------------------------------------

    def _path(self, request_id):
        if not isinstance(request_id, str) or not REQUEST_ID.match(request_id):
            raise LookupError(request_id)
        return self.root / "requests" / (request_id + ".json")

    def _read(self, request_id):
        path = self._path(request_id)
        try:
            if path.is_symlink() or path.stat().st_size > MAX_RESULT * 2:
                raise LookupError(request_id)
            record = json.loads(path.read_text())
        except (FileNotFoundError, ValueError, UnicodeDecodeError):
            raise LookupError(request_id) from None
        if not isinstance(record, dict) or record.get("id") != request_id or record.get("state") not in STATES \
                or record.get("tool") not in TOOLS:
            raise LookupError(request_id)
        return record

    def _write(self, record):
        record["updated_at"] = int(self.clock())
        atomic_write(self._path(record["id"]), record)
        return dict(record)

    def create(self, bot, tool, args):
        now = int(self.clock())
        record = {"version": 1, "id": secrets.token_hex(16), "bot": bot, "tool": tool, "area": TOOLS[tool],
                  "write": tool in WRITES, "args": args, "state": "waiting", "card": None, "result": None,
                  "error": None, "created_at": now, "updated_at": now}
        with self._locked():
            self._prune()
            return self._write(record)

    def get(self, request_id):
        with self._locked():
            return self._read(request_id)

    def remove(self, request_id):
        with self._locked(), contextlib.suppress(FileNotFoundError, LookupError):
            self._path(request_id).unlink()

    def open_requests(self):
        """Requests still open, oldest first: new ones, changes waiting for the person (the Mac keeps what it
        worded until then), and changes with a yes."""
        folder = self.root / "requests"
        found = []
        with self._locked():
            self._prune()
            if folder.is_dir():
                for path in folder.glob("*.json"):
                    with contextlib.suppress(LookupError):
                        record = self._read(path.stem)
                        if record["state"] != "done":
                            found.append(record)
        return sorted(found, key=lambda r: (r["created_at"], r["id"]))

    def _step(self, request_id, allowed, change):
        with self._locked():
            record = self._read(request_id)
            if record["state"] not in allowed or self.clock() - record["created_at"] > REQUEST_LIFETIME:
                raise Conflict(record["state"])
            change(record)
            return self._write(record)

    def prepare(self, request_id, card):
        """The Mac's words for a change it has not made. Changes only."""
        if not isinstance(card, str) or not card.strip() or len(card) > CARD_LIMIT:
            raise ValueError("Send the card's words.")

        def change(record):
            if not record["write"]:
                raise Conflict("read")
            record.update(state="prepared", card=card.strip())
        return self._step(request_id, ("waiting",), change)

    def approve(self, request_id):
        return self._step(request_id, ("prepared",), lambda r: r.update(state="approved"))

    def answer(self, request_id, result=None, error=None):
        """The Mac's answer: a read's result, a change it made, or why it didn't. A change is made only
        after the person's yes, so a result for one that was never approved is refused."""
        if (result is None) == (error is None):
            raise ValueError("Send a result or an error.")
        if error is not None and (not isinstance(error, str) or not error.strip() or len(error) > 600):
            raise ValueError("Send the error in a sentence.")
        if result is not None and (not isinstance(result, dict) or len(json.dumps(result)) > MAX_RESULT):
            raise ValueError("Send the result as a small object.")

        def change(record):
            if result is not None and record["write"] and record["state"] != "approved":
                raise Conflict(record["state"])
            record.update(state="done", result=result, error=error.strip() if error else None)
        return self._step(request_id, ("waiting", "approved"), change)

    def _prune(self):
        folder = self.root / "requests"
        if not folder.is_dir():
            return
        now = self.clock()
        for path in folder.glob("*.json"):
            with contextlib.suppress(OSError, ValueError, UnicodeDecodeError, AttributeError):
                if path.is_symlink():
                    path.unlink()
                    continue
                stamp = json.loads(path.read_text()).get("updated_at")
                if not isinstance(stamp, int) or now - stamp > REQUEST_LIFETIME:
                    path.unlink()


# The tools ------------------------------------------------------------------------------

def _schema(name, description, properties, required=()):
    return {"name": name, "description": description, "parameters": {
        "type": "object", "additionalProperties": False, "properties": properties, "required": list(required)}}


def _text(description):
    return {"type": "string", "description": description}


WHEN = "Local time on the Mac, like 2026-11-04T10:00, or a date like 2026-11-04 for a whole day."
ASKS = " The person is asked first, with exactly what will change; nothing happens without their yes."
SCHEMAS = {
    "calendar_events": _schema("calendar_events", "See the person's calendar events (on their Mac) in a time range. "
                               "Without start and end: from now to 7 days ahead.",
                               {"start": _text(WHEN), "end": _text(WHEN),
                                "calendar": _text("Only this calendar, by name.")}),
    "calendar_search": _schema("calendar_search", "Find calendar events whose title, place or notes contain these "
                               "words. Looks from 30 days ago to a year ahead unless you give start and end.",
                               {"text": _text("Words to look for."), "start": _text(WHEN), "end": _text(WHEN)},
                               ["text"]),
    "calendar_add_event": _schema("calendar_add_event", "Add an event to the person's calendar." + ASKS,
                                  {"title": _text("What it is."), "start": _text(WHEN),
                                   "end": _text(WHEN + " Defaults to an hour after start."),
                                   "all_day": {"type": "boolean"},
                                   "calendar": _text("Which calendar, by name. Defaults to their usual one."),
                                   "location": _text("Where."), "notes": _text("Notes.")},
                                  ["title", "start"]),
    "calendar_change_event": _schema("calendar_change_event", "Change one event: only the fields you send. A "
                                     "repeating event changes for that one time only." + ASKS,
                                     {"event_id": _text("The id from calendar_events or calendar_search."),
                                      "title": _text("New title."), "start": _text(WHEN), "end": _text(WHEN),
                                      "all_day": {"type": "boolean"},
                                      "calendar": _text("Move it to this calendar, by name."),
                                      "location": _text("New place."), "notes": _text("New notes.")},
                                     ["event_id"]),
    "calendar_delete_event": _schema("calendar_delete_event", "Delete one event. A repeating event is deleted for "
                                     "that one time only." + ASKS,
                                     {"event_id": _text("The id from calendar_events or calendar_search.")},
                                     ["event_id"]),
    "reminder_lists": _schema("reminder_lists", "See the person's reminder lists, with how many are still open.", {}),
    "reminders_open": _schema("reminders_open", "See open reminders, in one list or all of them.",
                              {"list": _text("Only this list, by name."),
                               "due_before": _text("Only those due before this. " + WHEN)}),
    "reminder_add": _schema("reminder_add", "Add a reminder." + ASKS,
                            {"title": _text("What to remember."),
                             "list": _text("Which list, by name. Defaults to their usual one."),
                             "due": _text("When it's due. " + WHEN), "notes": _text("Notes.")},
                            ["title"]),
    "reminder_complete": _schema("reminder_complete", "Mark a reminder as done." + ASKS,
                                 {"reminder_id": _text("The id from reminders_open.")}, ["reminder_id"]),
    "reminder_delete": _schema("reminder_delete", "Delete a reminder." + ASKS,
                               {"reminder_id": _text("The id from reminders_open.")}, ["reminder_id"]),
    "contacts_search": _schema("contacts_search", "Find people in the person's contacts by name. Gives each "
                               "match's name, phone numbers, email addresses and birthday, nothing else.",
                               {"name": _text("A name, or part of one.")}, ["name"]),
    "contact_add": _schema("contact_add", "Add someone to the person's contacts." + ASKS,
                           {"given_name": _text("First name."), "family_name": _text("Last name."),
                            "phone": _text("A phone number."), "email": _text("An email address."),
                            "birthday": _text("Like 1990-11-04, or --11-04 without a year.")},
                           ["given_name"]),
    "contact_change": _schema("contact_change", "Change someone in the person's contacts: add a phone number or "
                              "email address, set their birthday, or fix their name." + ASKS,
                              {"contact_id": _text("The id from contacts_search."),
                               "given_name": _text("New first name."), "family_name": _text("New last name."),
                               "add_phone": _text("A phone number to add."),
                               "add_email": _text("An email address to add."),
                               "birthday": _text("Like 1990-11-04, or --11-04 without a year.")},
                              ["contact_id"]),
}


def result(status, message=None, **extra):
    body = {"status": status}
    if message:
        body["message"] = message
    body.update(extra)
    return json.dumps(body, ensure_ascii=False)


def _wait(store, request_id, states, seconds, *, clock, sleep, beat=None):
    """The record once it reaches one of ``states``, or None when the wait runs out."""
    deadline = clock() + seconds
    while True:
        try:
            record = store.get(request_id)
        except (LookupError, OSError, ValueError):
            return None
        if record["state"] in states:
            return record
        if clock() >= deadline:
            return None
        if callable(beat):
            beat()
        sleep(POLL)


def _doubt(check):
    """A check that can't answer counts as yes: nobody can be asked, so nothing changes."""
    try:
        return bool(check())
    except Exception:
        return True


def handle(tool, args, *, store, bot, is_private, unattended, bypassed, ask,
           clock=time.monotonic, sleep=time.sleep, waiting=contextlib.nullcontext):
    """One call. Every injected piece is Hermes's in the real tool and a fake in tests."""
    area = TOOLS[tool]
    try:
        if is_private():
            return result("refused", MESSAGES["private"])
    except Exception:
        return result("refused", MESSAGES["private"])  # a damaged Private list refuses everyone
    if not store.enabled(bot, area):
        return result("off", MESSAGES["off"].format(name=AREA_NAMES[area]))
    try:
        args = clean(tool, args)
    except ValueError as exc:
        return result("error", str(exc))
    write = tool in WRITES
    try:
        record = store.create(bot, tool, args)
    except (OSError, ValueError):
        return result("error", MESSAGES["busy"])
    request_id = record["id"]
    try:
        with waiting() as beat:
            # A read comes back done; a change comes back worded (or refused, which is done too).
            record = _wait(store, request_id, ("prepared", "done"), MAC_WAIT, clock=clock, sleep=sleep, beat=beat)
        if record is None:
            return result("error", MESSAGES["no_mac"])
        if record["state"] == "done":
            if record.get("error"):
                return result("error", record["error"])
            return result("ok", **(record.get("result") or {}))
        card = record["card"]
        if _doubt(unattended):
            return result("blocked", MESSAGES["unattended"].format(card=card))
        if _doubt(bypassed):
            return result("blocked", MESSAGES["bypassed"].format(card=card))
        try:
            decision = ask(card, f"{RULE_PREFIX}{area}:{request_id}")
        except Exception:
            decision = {"approved": False, "outcome": "notify_failed"}
        if not isinstance(decision, dict) or decision.get("approved") is not True:
            quiet = isinstance(decision, dict) and decision.get("outcome") in ("timeout", "cancelled", "notify_failed")
            return result("declined", MESSAGES["no_answer" if quiet else "declined"])
        try:
            store.approve(request_id)
        except (Conflict, LookupError, OSError, ValueError):
            return result("error", MESSAGES["busy"])
        with waiting() as beat:
            record = _wait(store, request_id, ("done",), APPLY_WAIT, clock=clock, sleep=sleep, beat=beat)
        if record is None:
            return result("error", MESSAGES["unsure"])
        if record.get("error"):
            return result("error", record["error"])
        return result("done", **(record.get("result") or {}))
    finally:
        # Nothing waits once the tool has its answer; a late Mac finds no request and does nothing.
        store.remove(request_id)


# Hermes glue ----------------------------------------------------------------------------

def hermes_ask(description, rule):
    """Hermes's own human gate: the same card, alert and Allow once / Deny as any approval."""
    from tools.approval import request_tool_approval
    return request_tool_approval("apple_data", description, rule_key=rule)


def register(ctx, main_home, profile, is_private):
    """The tools, one toolset per area, for a bot that is not private. Each shows only while its switch is on."""
    from .ask_first import hermes_bypassed, hermes_unattended
    from .sign_ins import hermes_waiting
    store = Store(main_home)
    unattended = hermes_unattended(ctx)

    def shown(area):
        def check():
            try:
                return not is_private() and store.enabled(profile, area)
            except Exception:
                return False
        return check

    def make(tool):
        def run(args, session_id=None, **_):
            return handle(tool, args, store=store, bot=profile, is_private=is_private, unattended=unattended,
                          bypassed=lambda: hermes_bypassed(session_id), ask=hermes_ask, waiting=hermes_waiting)
        return run

    checks = {area: shown(area) for area in AREAS}
    for tool, area in TOOLS.items():
        ctx.register_tool(name=tool, toolset=TOOLSETS[area], schema=SCHEMAS[tool], handler=make(tool),
                          check_fn=checks[area], description=SCHEMAS[tool]["description"])
