"""Saved sign-ins: a helper asks to sign in to a site, the person says yes, and Nollie on the Mac
types the saved username and password into the helper's computer.

Passwords never come here. They live only in the Mac's Keychain, behind Touch ID or the Mac's
password for every read. While one is being typed, and for SETTLE seconds after, ``PicturePause``
refuses every screenshot, recording and action on a computer, and the preview pauses too. This add-on keeps three small things in the main bot's home, under
``nollie-workflow/sign-ins/`` (folders 0700, files 0600):

- ``sites.json``: which sites have a saved sign-in, as the Mac app last sent them. Sites only.
- ``requests/<id>.json``: one request while it is open: bot, site, computer, state, who answered.
- ``history.jsonl``: one line per use: when, bot, site, who answered, the outcome. Never a secret.

The tool the helper sees answers only with a status and a short sentence: signed in, declined,
not saved yet, or why it didn't happen. It never returns a username, a password or a note.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import re
import secrets
import threading
import time

from .workflow_core import atomic_write, file_lock

FOLDER = "sign-ins"
MAX_SITES = 500
KEEP_HISTORY_DAYS = 90
MAX_HISTORY_LINES = 2000
REQUEST_LIFETIME = 3600
# How long the tool waits for the Mac after a yes: Touch ID on the Mac, then the typing.
FILL_WAIT = 120.0
# More time once the Mac has started typing, so a slow computer is not cut off halfway.
FILL_GRACE = 60.0
POLL = 0.5
# Pictures of every computer stay paused this long after a fill ends: Return was just pressed and the
# page may still show the password field for a moment.
SETTLE = 10.0
# A request in one of these states may have a password on screen right now.
TYPING = ("approved", "filling")
# Stopped while the Mac was typing: it may type for a while yet (its short wait, then up to its 20 s limit).
FILL_TAIL = 35.0

REQUEST_ID = re.compile(r"[0-9a-f]{32}\Z")
LABEL = re.compile(r"(?!-)[a-z0-9-]{1,63}(?<!-)\Z")
# A Cua computer the helper names (local:<name>, cloud:<name>, or a bare name), or "mac".
SPACE_TARGET = re.compile(r"(local|cloud):[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
BARE_TARGET = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
FOCUSES = ("username", "password")
APPROVERS = ("mac", "iphone")
# What the Mac may report after it tried. A reason is one of these words, never free text.
MAC_OUTCOMES = ("signed_in", "failed", "cancelled")
MAC_REASONS = ("not_saved_here", "fill_unavailable", "computer_unavailable", "fill_failed", "private", "touch_id")
STATES = ("asking", "approved", "filling", "done")
RULE_PREFIX = "nollie-sign-in:"


class Conflict(Exception):
    """The request is not in a state that allows this step (answered, finished or gone)."""


def normalize_site(raw):
    """The host of a site the way it is saved and asked for: lowercase, punycode, no scheme,
    path, port or trailing dot. None for anything that is not a plain host name."""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text or len(text) > 300 or any(c.isspace() for c in text):
        return None
    text = re.sub(r"\A[a-zA-Z][a-zA-Z0-9+.-]*://", "", text)
    text = re.split(r"[/?#]", text, maxsplit=1)[0]
    if "@" in text:
        return None  # user info in an address hides where it really goes
    text = re.sub(r":[0-9]{1,5}\Z", "", text).rstrip(".")
    try:
        host = text.encode("idna").decode("ascii").lower()
    except (UnicodeError, ValueError):
        return None
    labels = host.split(".")
    if len(host) > 253 or len(labels) < 2 or not all(LABEL.match(label) for label in labels):
        return None
    if labels[-1].isdigit():
        return None  # an address, not a site name
    return host


def matches(saved, requested):
    """A saved site covers itself and its subdomains: example.com covers login.example.com,
    never example.com.evil.net or myexample.com."""
    return requested == saved or requested.endswith("." + saved)


def valid_computer(value):
    if not isinstance(value, str):
        return None
    value = value.strip()
    if value.lower() in ("mac", "this mac"):
        return "mac"
    return value if SPACE_TARGET.fullmatch(value) or BARE_TARGET.fullmatch(value) else None


class Store:
    """The add-on's side of saved sign-ins, shared by the tool (in the gateway) and the routes
    (in the dashboard) through files under one lock."""

    def __init__(self, main_home, clock=time.time):
        self.root = Path(main_home) / "nollie-workflow" / FOLDER
        self.clock = clock

    @contextlib.contextmanager
    def _locked(self):
        for path in (self.root.parent, self.root):
            if path.is_symlink():
                raise ValueError("a sign-ins folder is a link")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with file_lock(self.root / "sign-ins.lock"):
            yield

    # Sites ------------------------------------------------------------------------------

    def sites(self):
        path = self.root / "sites.json"
        try:
            if path.is_symlink() or path.stat().st_size > 64 * 1024:
                raise ValueError("the site list is not readable")
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return []
        except UnicodeDecodeError:
            raise ValueError("the site list is not readable") from None
        sites = document.get("sites") if isinstance(document, dict) and document.get("version") == 1 else None
        if not isinstance(sites, list) or not all(isinstance(s, str) and normalize_site(s) == s for s in sites):
            raise ValueError("the site list is not valid")
        return sites

    @staticmethod
    def clean_sites(sites):
        if not isinstance(sites, list) or len(sites) > MAX_SITES:
            raise ValueError(f"Send a list of at most {MAX_SITES} sites.")
        cleaned = set()
        for site in sites:
            host = normalize_site(site)
            if host is None:
                raise ValueError("Each site must be a name like example.com.")
            cleaned.add(host)
        return sorted(cleaned)

    def save_sites(self, sites):
        cleaned = self.clean_sites(sites)
        with self._locked():
            atomic_write(self.root / "sites.json", {"version": 1, "sites": cleaned})
        return cleaned

    def saved(self, site):
        return any(matches(saved, site) for saved in self.sites())

    # Requests ---------------------------------------------------------------------------

    def _path(self, request_id):
        if not isinstance(request_id, str) or not REQUEST_ID.match(request_id):
            raise LookupError(request_id)
        return self.root / "requests" / (request_id + ".json")

    def _read(self, request_id):
        path = self._path(request_id)
        try:
            if path.is_symlink():
                raise LookupError(request_id)
            record = json.loads(path.read_text())
        except (FileNotFoundError, ValueError, UnicodeDecodeError):
            raise LookupError(request_id) from None
        if not isinstance(record, dict) or record.get("id") != request_id or record.get("state") not in STATES:
            raise LookupError(request_id)
        return record

    def _write(self, record):
        atomic_write(self._path(record["id"]), record)
        return dict(record)

    def create(self, bot, site, computer, focus):
        now = int(self.clock())
        record = {"version": 1, "id": secrets.token_hex(16), "bot": bot, "site": site, "computer": computer,
                  "focus": focus, "state": "asking", "approver": None, "outcome": None, "reason": None,
                  "code_note": False, "created_at": now, "updated_at": now}
        with self._locked():
            self._prune()
            return self._write(record)

    def get(self, request_id):
        with self._locked():
            return self._read(request_id)

    def open_requests(self):
        """Requests still waiting on someone, oldest first."""
        folder = self.root / "requests"
        with self._locked():
            self._prune()
            found = []
            if folder.is_dir() and not folder.is_symlink():
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
            record["updated_at"] = int(self.clock())
            return self._write(record)

    def claim(self, request_id, approver):
        """Who is answering: the first device to say so. Only a label for the history; the Mac's
        Touch ID before every fill is what keeps the password safe."""
        if approver not in APPROVERS:
            raise ValueError("unknown approver")
        with self._locked():
            record = self._read(request_id)
            if record["state"] != "asking" or record["approver"] not in (None, approver):
                raise Conflict(record["state"])
            record["approver"] = approver
            record["updated_at"] = int(self.clock())
            return self._write(record)

    def approve(self, request_id):
        return self._step(request_id, ("asking",), lambda r: r.update(state="approved"))

    def start(self, request_id):
        """The Mac begins typing. Only once, and only while the tool still waits."""
        return self._step(request_id, ("approved",), lambda r: r.update(state="filling"))

    def report(self, request_id, outcome, reason=None, code_note=False):
        """The Mac's answer after it tried."""
        if outcome not in MAC_OUTCOMES or (reason is not None and reason not in MAC_REASONS):
            raise ValueError("unknown outcome")
        return self._step(request_id, ("approved", "filling"), lambda r: r.update(
            state="done", outcome=outcome, reason=reason, code_note=bool(code_note) and outcome == "signed_in",
            quiet_until=self.clock() + SETTLE))

    def close(self, request_id, outcome):
        """The tool gives up on a request that has not finished (no answer, a no, a timeout)."""
        with self._locked():
            record = self._read(request_id)
            if record["state"] == "done":
                return record
            # Stopped mid-fill: the Mac may still be typing, so pictures stay paused for its whole fill.
            tail = FILL_TAIL if record["state"] == "filling" else SETTLE
            record.update(state="done", outcome=outcome, updated_at=int(self.clock()), quiet_until=self.clock() + tail)
            return self._write(record)

    def expire_unless_filling(self, request_id):
        """After the wait: an approved request nobody started is closed, so a late Mac never types.
        One being typed keeps going a little longer (returns it unchanged)."""
        with self._locked():
            record = self._read(request_id)
            if record["state"] == "approved":
                record.update(state="done", outcome="expired", updated_at=int(self.clock()),
                              quiet_until=self.clock() + SETTLE)
                return self._write(record)
            return record

    def _prune(self):
        folder = self.root / "requests"
        if not folder.is_dir() or folder.is_symlink():
            return
        now = self.clock()
        for path in folder.glob("*.json"):
            with contextlib.suppress(OSError, ValueError, UnicodeDecodeError, AttributeError):
                if path.is_symlink():
                    path.unlink()
                    continue
                stamp = json.loads(path.read_text()).get("updated_at")
                if not isinstance(stamp, int) or now - stamp > REQUEST_LIFETIME * 2:
                    path.unlink()

    # History ----------------------------------------------------------------------------

    def record_use(self, bot, site, outcome, approver=None, computer=None):
        entry = {"v": 1, "at": int(self.clock()), "bot": bot, "site": site, "outcome": outcome,
                 "approver": approver if approver in APPROVERS else None,
                 "computer": "mac" if computer == "mac" else ("space" if computer else None)}
        path = self.root / "history.jsonl"
        with self._locked():
            if path.is_symlink():
                raise ValueError("the history is a link")
            lines = self._history_lines(path)
            lines.append(json.dumps(entry, separators=(",", ":")))
            cutoff = self.clock() - KEEP_HISTORY_DAYS * 86400
            kept = [line for line in lines if _line_time(line) >= cutoff][-MAX_HISTORY_LINES:]
            temporary = path.with_name(".history-" + secrets.token_hex(4))
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(fd, "w") as handle:
                    handle.write("\n".join(kept) + "\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, path)
            finally:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary)
        return entry

    @staticmethod
    def _history_lines(path):
        try:
            return [line for line in path.read_text().splitlines() if line.strip()]
        except FileNotFoundError:
            return []

    def history(self, days=30, private=frozenset()):
        path = self.root / "history.jsonl"
        cutoff = self.clock() - days * 86400
        with self._locked():
            if path.is_symlink():
                raise ValueError("the history is a link")
            lines = self._history_lines(path)
        entries = []
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if (isinstance(entry, dict) and isinstance(entry.get("at"), int) and entry["at"] >= cutoff
                    and str(entry.get("bot", "")).lower() not in private):
                entries.append({k: entry.get(k) for k in ("at", "bot", "site", "outcome", "approver", "computer")})
        return list(reversed(entries))[:200]


# Pictures pause while a password may be on screen --------------------------------------------

PICTURE_WORDS = ("screenshot", "screen", "capture", "record", "snapshot", "vision", "camera", "display", "frame",
                 "stream", "vnc", "look")
COMPUTER_PREFIXES = ("mcp__cua__", "mcp__cua_recorder__", "mcp__nollie_mac__", "mcp__computer", "mcp__cua_")
COMPUTER_TOOLS = frozenset(("computer_use",))
CAPTURE_COMMANDS = re.compile(r"(?i)\b(cua|screencapture|ffmpeg|avfoundation|vncsnapshot|vncviewer|xwd|scrot|"
                              r"gnome-screenshot|grim|import\s+-window|screenshot|cua-driver|cliclick|osascript|"
                              r"peekaboo)\b")
PAUSED = ("Paused for a moment: Nollie is typing a saved sign-in, so pictures of computers and actions on them "
          "wait until it's done. Try again in about {seconds} seconds.")


def typing_now(main_home, clock=time.time):
    """Requests that may have a password on screen now: being typed, or finished less than SETTLE ago.

    Read without the lock, so a hook can ask on every call. A request file that can't be read counts
    as typing (fails closed), and so does a sign-ins folder that is a link."""
    root = Path(main_home) / "nollie-workflow" / FOLDER
    folder = root / "requests"
    now = clock()
    try:
        if root.is_symlink() or folder.is_symlink():
            return [{"bot": None, "computer": None, "until": None}]
        paths = list(folder.glob("*.json")) if folder.is_dir() else []
    except OSError:
        return [{"bot": None, "computer": None, "until": None}]
    found = []
    for path in paths:
        try:
            record = json.loads(path.read_text())
            state, created = record.get("state"), record.get("created_at")
            updated = record.get("updated_at")
            if not isinstance(created, int) or not isinstance(updated, int) or state not in STATES:
                raise ValueError("damaged")
        except (OSError, ValueError, UnicodeDecodeError, AttributeError):
            try:
                if now - path.stat().st_mtime > REQUEST_LIFETIME:
                    continue
            except OSError:
                continue
            found.append({"bot": None, "computer": None, "until": None})
            continue
        if state in TYPING and now - created <= REQUEST_LIFETIME:
            found.append({"bot": record.get("bot"), "computer": record.get("computer"), "until": None})
        elif state == "done":
            quiet = record.get("quiet_until")
            # Seconds are whole in updated_at, so an older record without quiet_until gets one more.
            until = quiet if isinstance(quiet, (int, float)) and not isinstance(quiet, bool) else updated + SETTLE + 1
            if now < until:
                found.append({"bot": record.get("bot"), "computer": record.get("computer"), "until": until})
    return found


def seconds_left(windows, clock=time.time):
    """Roughly how long until pictures resume, for the message: a fill in progress gets the full wait."""
    if any(w["until"] is None for w in windows):
        return int(SETTLE) + 5
    return max(1, int(max(w["until"] for w in windows) - clock() + 0.999))


def shows_a_computer(tool, args):
    """True for any call that could take a picture of a computer, record it, or act on it."""
    tool = str(tool or "")
    args = args if isinstance(args, dict) else {}
    if tool in ("tool_call", "connectors__execute"):
        calls = args.get("calls")
        if isinstance(calls, str):
            try:
                calls = json.loads(calls)
            except ValueError:
                return True
        if not isinstance(calls, list):
            calls = [{"name": args.get("name"), "arguments": args.get("arguments")}]
        for call in calls:
            if not isinstance(call, dict) or not isinstance(call.get("name"), str):
                return True
            inner = call.get("arguments")
            if isinstance(inner, str):
                try:
                    inner = json.loads(inner)
                except ValueError:
                    inner = {"text": inner}
            if shows_a_computer(call["name"], inner if isinstance(inner, dict) else {}):
                return True
        return False
    if tool in COMPUTER_TOOLS or tool.startswith(COMPUTER_PREFIXES):
        return True
    lowered = tool.lower()
    if any(word in lowered for word in PICTURE_WORDS):
        return True
    if tool in ("terminal", "process", "process_manage", "execute_code"):
        text = " ".join(str(args.get(k) or "") for k in ("command", "cmd", "code", "script", "input", "data",
                                                         "text"))
        return bool(CAPTURE_COMMANDS.search(text))
    return False


class Recordings:
    """Screen recordings a bot started through a tool and hasn't stopped. A fill never starts while one
    runs: the pause refuses new pictures, but can't stop a recording already going."""

    def __init__(self):
        self.lock = threading.Lock()
        self.running = {}

    @staticmethod
    def _step(tool):
        lowered = str(tool or "").lower()
        if "record" not in lowered:
            return None
        if any(w in lowered for w in ("stop", "end", "finish", "cancel")):
            return "stop"
        if any(w in lowered for w in ("start", "begin")) or lowered.endswith("__record"):
            return "start"
        return None

    def post_tool_call(self, tool_name=None, session_id=None, status=None, **_):
        try:
            step = self._step(tool_name)
            if step is None or status in ("blocked", "error"):
                return None
            with self.lock:
                if step == "start":
                    self.running[session_id or ""] = time.time()
                else:
                    self.running.pop(session_id or "", None)
        except Exception:
            pass
        return None

    def any(self):
        with self.lock:
            return bool(self.running)


RECORDINGS = Recordings()


class PicturePause:
    """The ``pre_tool_call`` hook: refuses pictures of computers, and actions on them, while a saved
    sign-in is being typed and for SETTLE seconds after."""

    def __init__(self, main_home, clock=time.time):
        self.main_home = main_home
        self.clock = clock

    def hook(self, tool_name=None, args=None, **_):
        try:
            if not shows_a_computer(tool_name, args):
                return None
            windows = typing_now(self.main_home, self.clock)
        except Exception:
            windows = [{"bot": None, "computer": None, "until": None}]
        if not windows:
            return None
        return {"action": "block", "message": PAUSED.format(seconds=seconds_left(windows, self.clock))}

    def result(self, tool_name=None, args=None, result=None, **_):
        """``transform_tool_result``: a call that passed the check but finished while a fill began (one held
        for an approval, say) gives back no picture. Hermes's own copy of the picture is removed too."""
        try:
            if not shows_a_computer(tool_name, args) or not typing_now(self.main_home, self.clock):
                return None
        except Exception:
            pass
        _remove_cached_pictures(result)
        return PAUSED.format(seconds=int(SETTLE)) + " What it would have shown was thrown away."


_MEDIA = re.compile(r"(?:MEDIA:|\"(?:screenshot_path|screenshot_file_path|path|file)\"\s*:\s*\")([^\s\"]+)")


def _remove_cached_pictures(result):
    """Deletes the pictures a refused result points at, but only inside Hermes's own cache folders."""
    try:
        from hermes_constants import get_hermes_home
        cache = (Path(get_hermes_home()) / "cache").resolve()
    except Exception:
        return
    text = result if isinstance(result, str) else json.dumps(result, default=str)
    for match in _MEDIA.finditer(text or ""):
        try:
            path = Path(match.group(1)).resolve()
            if cache in path.parents and path.is_file() and path.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp",
                                                                                   ".gif", ".mp4", ".mov"):
                path.unlink()
        except OSError:
            continue


def _line_time(line):
    try:
        value = json.loads(line).get("at")
        return value if isinstance(value, int) else 0
    except (ValueError, AttributeError):
        return 0


# The tool --------------------------------------------------------------------------------

DESCRIPTION = (
    "Sign in to a website with a sign-in the person saved in Nollie on their Mac. Use it when you reach a "
    "sign-in page on your computer. First click the username box (or the password box when the page asks "
    "for the password alone), then call this. The person is asked to allow it; Nollie on the Mac then types "
    "the username and password and presses Return. You are never told them, and you must never ask the person "
    "for a password in the chat. While Nollie types, and for a few seconds after, screenshots and actions on "
    "computers are paused. Afterwards take a screenshot to check the page. Answers: signed_in, "
    "declined, not_saved (no saved sign-in for that site yet) or not_signed_in with the reason."
)
SCHEMA = {"name": "request_sign_in", "description": DESCRIPTION, "parameters": {
    "type": "object", "additionalProperties": False,
    "properties": {
        "site": {"type": "string", "description": "The site's address as shown in the address bar, like example.com."},
        "computer": {"type": "string", "description":
                     "The computer you are signing in on: your Cua computer's name, like local:dev, or 'mac' for this Mac."},
        "focus": {"type": "string", "enum": list(FOCUSES),
                  "description": "Which box has focus now: username (default) or password."},
    }, "required": ["site", "computer"]}}


def result(status, message, **extra):
    return json.dumps({"status": status, "message": message, **extra})


MESSAGES = {
    "private": "Saved sign-ins aren't available to this bot.",
    "unattended": "Sign-ins need the person, so they can't happen in a schedule or Board work. Ask in a chat instead.",
    "bad_site": "Send the site's address, like example.com.",
    "bad_computer": "Say which computer you're signing in on: your Cua computer's name, like local:dev, or mac.",
    "declined": "The person said no. Don't try again unless they ask.",
    "no_answer": "Nobody answered, so nothing was filled in. Don't try again unless the person asks.",
    "expired": "Nollie on the Mac didn't fill it in. It may be closed. Ask the person to open Nollie on their Mac and try again.",
    "cancelled": "The person didn't confirm on the Mac, so nothing was filled in.",
    "interrupted": "The sign-in was stopped. Something may have been typed already; take a screenshot to check.",
    "not_saved_here": "The Mac no longer has a saved sign-in for this site. Ask the person to add it in Nollie on their Mac.",
    "fill_unavailable": "Nollie can't type into this computer yet. Ask the person to sign in themselves.",
    "computer_unavailable": "Nollie couldn't reach that computer. Check it's running and that the name is right.",
    "fill_failed": "Nollie couldn't finish typing the sign-in. Take a screenshot and ask the person to check.",
    "touch_id": "The Mac couldn't confirm it was the person, so nothing was filled in.",
    "busy": "The sign-in couldn't be started right now. Try again in a moment.",
    "recording": "A screen recording is running. Stop it first, then ask again: Nollie never types a sign-in "
                 "while the screen is being recorded.",
}


def not_saved(site):
    return (f"There's no saved sign-in for {site} yet. Ask the person to add one in Nollie on their Mac: "
            "Settings, Sign-ins. Never ask for the password in the chat.")


def signed_in(site, code_note):
    text = f"Signed in to {site}: Nollie typed the saved sign-in and pressed Return. Take a screenshot to check the page."
    if code_note:
        text += " This site may ask for a one-time code next. Ask the person for it."
    return text


def handle(args, *, store, bot, is_private, unattended, ask, interrupted=lambda: False,
           clock=time.monotonic, sleep=time.sleep, waiting=contextlib.nullcontext, recording=RECORDINGS.any):
    """One request_sign_in call. Every injected piece is Hermes's in the real tool and a fake in tests."""
    try:
        if is_private():
            return result("refused", MESSAGES["private"])
    except Exception:
        return result("refused", MESSAGES["private"])  # a damaged Private list refuses everyone
    if unattended():
        return result("not_signed_in", MESSAGES["unattended"])
    if recording():
        return result("not_signed_in", MESSAGES["recording"])
    args = args if isinstance(args, dict) else {}
    site = normalize_site(args.get("site"))
    if site is None:
        return result("not_signed_in", MESSAGES["bad_site"])
    computer = valid_computer(args.get("computer"))
    if computer is None:
        return result("not_signed_in", MESSAGES["bad_computer"])
    focus = args.get("focus") or "username"
    if focus not in FOCUSES:
        focus = "username"
    try:
        if not store.saved(site):
            store.record_use(bot, site, "not_saved", computer=computer)
            return result("not_saved", not_saved(site))
        record = store.create(bot, site, computer, focus)
    except (OSError, ValueError):
        return result("not_signed_in", MESSAGES["busy"])
    request_id = record["id"]

    def finish(outcome, status, message, approver=None, **extra):
        with contextlib.suppress(Exception):
            current = store.get(request_id)
            approver = current.get("approver") or approver
        with contextlib.suppress(Exception):
            store.record_use(bot, site, outcome, approver=approver, computer=computer)
        return result(status, message, **extra)

    try:
        decision = ask(f"Sign in to {site}", RULE_PREFIX + request_id)
    except Exception:
        decision = {"approved": False, "outcome": "notify_failed"}
    if not isinstance(decision, dict) or decision.get("approved") is not True:
        outcome = "no_answer" if isinstance(decision, dict) and decision.get("outcome") in ("timeout", "cancelled", "notify_failed") else "declined"
        with contextlib.suppress(Exception):
            store.close(request_id, outcome)
        return finish(outcome, "declined", MESSAGES[outcome])
    try:
        store.approve(request_id)
    except (Conflict, LookupError, OSError, ValueError):
        with contextlib.suppress(Exception):
            store.close(request_id, "failed")
        return finish("failed", "not_signed_in", MESSAGES["busy"])

    deadline = clock() + FILL_WAIT
    grace_used = False
    with waiting() as beat:
        while True:
            try:
                record = store.get(request_id)
            except (LookupError, OSError, ValueError):
                return finish("failed", "not_signed_in", MESSAGES["busy"])
            if record["state"] == "done":
                break
            if interrupted():
                with contextlib.suppress(Exception):
                    record = store.close(request_id, "interrupted")
                break
            if clock() >= deadline:
                with contextlib.suppress(Exception):
                    record = store.expire_unless_filling(request_id)
                if record["state"] == "filling" and not grace_used:
                    grace_used = True
                    deadline = clock() + FILL_GRACE
                    continue
                if record["state"] != "done":
                    with contextlib.suppress(Exception):
                        record = store.close(request_id, "expired")
                break
            if callable(beat):
                beat()
            sleep(POLL)

    outcome, reason = record.get("outcome"), record.get("reason")
    if outcome != "expired" or grace_used:
        # The page may still show what was typed: wait out the pause before the helper looks.
        settle_until = clock() + SETTLE
        while clock() < settle_until:
            sleep(min(POLL, max(0.0, settle_until - clock())))
    if outcome == "signed_in":
        return finish("signed_in", "signed_in", signed_in(site, record.get("code_note")))
    if outcome == "cancelled":
        return finish("cancelled", "declined", MESSAGES["cancelled"])
    if outcome in ("expired", "interrupted"):
        return finish(outcome, "not_signed_in", MESSAGES[outcome])
    return finish("failed", "not_signed_in", MESSAGES.get(reason or "", MESSAGES["fill_failed"]))


# Hermes glue -----------------------------------------------------------------------------

def hermes_ask(description, rule):
    """Hermes's own human gate: the same card, alert and Allow once / Deny as any approval."""
    from tools.approval import request_tool_approval
    return request_tool_approval("request_sign_in", description, rule_key=rule)


def hermes_interrupted():
    try:
        from tools.interrupt import is_interrupted
        return bool(is_interrupted())
    except Exception:
        return False


@contextlib.contextmanager
def hermes_waiting():
    """Tells Hermes the turn is waiting on a person, so its watchdog leaves it be."""
    try:
        from tools.approval_context import get_current_session_key
        from tools.approval_human_wait import activity_heartbeat, human_wait_window
        heartbeat = activity_heartbeat("waiting for the Mac to fill in a sign-in")
        window = human_wait_window(get_current_session_key())
    except Exception:
        yield
        return
    with window:
        yield heartbeat


def register(ctx, main_home, profile, is_private):
    """The request_sign_in tool, in its own toolset (``nollie_sign_in``), for a bot that is not private."""
    store = Store(main_home)

    def unattended():
        try:
            if ctx.current_cron_execution() is not None:
                return True
        except Exception:
            pass
        if os.environ.get("HERMES_KANBAN_TASK"):
            return True
        try:
            from gateway.session_context import get_session_env
            return str(get_session_env("HERMES_CRON_SESSION", "")).strip().lower() in ("1", "true", "yes")
        except Exception:
            return False

    def tool(args, **_):
        return handle(args, store=store, bot=profile, is_private=is_private, unattended=unattended,
                      ask=hermes_ask, interrupted=hermes_interrupted, waiting=hermes_waiting)

    ctx.register_tool(name="request_sign_in", toolset="nollie_sign_in", schema=SCHEMA,
                      handler=tool, description=DESCRIPTION)
