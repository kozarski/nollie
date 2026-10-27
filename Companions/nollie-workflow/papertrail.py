"""Papertrail: a wordless record of what one bot sent off this Mac.

One JSON line per model call, helper call or online tool, kept in the bot's own home under
``nollie-workflow/papertrail/<YYYY-MM-DD>.jsonl``. Only when, where and how much: never prompts,
replies, queries, URLs or arguments. Stdlib only here; Hermes is imported lazily and best effort.

Each line also says why it went, in ids and short names only: what started the work (a chat, a schedule,
a Board task, a schedule's helper), on which chat app, how many messages went, whether the bot's backup
model answered, and the person's approval answers in the same turn.

Nollie Runtime's door writes "door" lines into the same files: one per connection Hermes or a program it
started made, with the host, port, time and kind of program (``hermes``, ``terminal``, ``code``, ``mcp``,
``model``, ``reader``, ``program``). The reader puts each with the reply it happened in, by time.
"""
from __future__ import annotations

import atexit
from collections import deque
import contextlib
from datetime import date, datetime, timedelta
import errno
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import stat
import threading
import time
from urllib.parse import urlsplit
import weakref

from .apple_data import READS as LOCAL_READS
from .sign_ins import normalize_site

KEEP_DAYS = 35
MAX_ENTRIES = 200
WINDOW_SECONDS = 600
LOCK_WAIT_SECONDS = 2.0
MAX_WAITING = 5000
HOOKS = ("post_api_request", "api_request_error", "post_auxiliary_call", "post_tool_call",
         "post_approval_response")
# "icloud": a note Nollie on the Mac sealed for the person's own linked iPhone and put in their iCloud.
ROUTES = frozenset({"mac", "network", "online", "icloud"})
# An "approval" line is a person's answer, kept for the turn's Why. Older readers skip it by its source.
SOURCES = frozenset({"model", "helper", "tool", "approval", "away", "door"})
# What kind of program made a connection through the door.
# "direct": a connection the network filter saw going around the door.
DOOR_KINDS = frozenset({"hermes", "terminal", "code", "mcp", "model", "reader", "program", "direct"})
# A connection this close to a reply's own calls belongs to that reply; otherwise it stands alone,
# with the others of its bot in the same hour.
DOOR_SLACK = 5
DOOR_WINDOW = 3600
DOOR_HOST = re.compile(r"[A-Za-z0-9._:-]{1,255}\Z")
# What the Mac app may say it sent through iCloud: kinds of note only, never their words.
AWAY_KINDS = frozenset({"reply", "card", "helpers", "stopped"})
# A bot used apps on this Mac through Nollie Computer: the apps' names and the counts, never the screen. The model
# that looked runs on the Mac, so no picture of the screen left (Hermes's own computer_use is refused).
MAC_SESSION = "mac_session"
MAX_MAC_APPS = 8
MAX_MAC_SESSIONS = 50
APP_NAME = re.compile(r"[^\w .&+'-]")
ORIGINS = frozenset({"chat", "schedule", "board", "helper"})
CHOICES = frozenset({"once", "session", "always", "deny"})
ASK_KINDS = frozenset({"send", "buy", "post", "delete", "unsure"})
ASK_PREFIX = "nollie-ask-first:"
MAX_APPROVALS = 8
LOCAL_RUNTIMES = frozenset({"llamacpp", "llama.cpp", "llama-cpp", "ollama", "lmstudio", "lm-studio", "mlx",
                            "local"})
LOCAL_SCHEMES = frozenset({"process", "unix", "file"})
# RFC 1918, link-local, CGNAT (Tailscale) and their IPv6 counterparts: off this Mac, still at home.
HOME_NETWORKS = tuple(ipaddress.ip_network(net) for net in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "fe80::/10", "fc00::/7"))
SEARCH_TOOLS = frozenset({"web_search", "x_search"})
PAGE_TOOLS = frozenset({"web_extract", "browser_navigate"})
IMAGE_TOOLS = frozenset({"image_generate"})
# Hermes's web_extract reads at most this many of the URLs it is given (tools/web_tools.py).
EXTRACT_MAX_URLS = 5
DAY_FILE = re.compile(r"(\d{4}-\d{2}-\d{2})\.jsonl\Z")
SERVICE_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z")
PLATFORM_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}\Z")
HOST_TEXT = re.compile(r"[A-Za-z0-9._:%\[\]-]{1,255}\Z")
UNSAFE_ID = re.compile(r"[^A-Za-z0-9._:/@+=-]")
PAYMENT_TOOL = "request_payment"
PAID_CARD = re.compile(r"ending ([0-9]{4})\Z")
TOKEN_FIELDS = (("in", "input_tokens"), ("out", "output_tokens"), ("cache", "cache_read_tokens"),
                ("think", "reasoning_tokens"))


class LinkedPath(OSError):
    """A Papertrail folder or file that is a link. Nothing is written through it."""


def _split(base_url):
    text = str(base_url or "").strip()
    if not text:
        return None
    return urlsplit(text if "://" in text else "//" + text)


def _host_route(name):
    name = (name or "").rstrip(".").lower()
    if not name:
        return "online"
    if name in ("localhost", "0.0.0.0"):
        return "mac"
    try:
        address = ipaddress.ip_address(name.split("%", 1)[0])
    except ValueError:
        address = None
    if address is not None:
        address = getattr(address, "ipv4_mapped", None) or address
        if address.is_loopback or address.is_unspecified:
            return "mac"
        return "network" if any(address in net for net in HOME_NETWORKS) else "online"
    return "network" if name.endswith(".local") or "." not in name else "online"


def route(provider, base_url):
    """"mac", "network" or "online" for one call. When unsure, the call left."""
    local_runtime = str(provider or "").strip().lower() in LOCAL_RUNTIMES
    try:
        parts = _split(base_url)
        if parts is None:
            return "mac" if local_runtime else "online"
        if parts.scheme.lower() in ("", "http", "https"):
            return _host_route(parts.hostname)
        if not local_runtime:
            return "online"
        # A local runtime run as a process or over a socket file is on this Mac; any other scheme
        # goes by its host.
        return "mac" if parts.scheme.lower() in LOCAL_SCHEMES else _host_route(parts.hostname)
    except ValueError:
        return "online"


def host(base_url):
    """``scheme://host[:port]`` for an HTTP(S) URL, never its path, query or credentials; else None."""
    try:
        parts = _split(base_url)
        if parts is None or parts.scheme.lower() not in ("http", "https") or not parts.hostname:
            return None
        name, port = parts.hostname, parts.port
    except ValueError:
        return None
    if not HOST_TEXT.match(name):
        return None
    name = f"[{name}]" if ":" in name else name
    return f"{parts.scheme.lower()}://{name}" + ("" if port is None else f":{port}")


def _id(value, limit=128):
    return UNSAFE_ID.sub("_", str(value or "").strip())[:limit]


def _count(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return 0
    return int(value)


def _when(value, clock):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0:
        return round(float(value), 3)
    return round(clock(), 3)


def _open(path, flags):
    """Open a regular file without following links, kept private to the user."""
    try:
        fd = os.open(path, flags | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
    except OSError as exc:
        if exc.errno == errno.ELOOP or Path(path).is_symlink():
            raise LinkedPath("a Papertrail file is a link") from None
        raise
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise LinkedPath("a Papertrail file is not a regular file")
        if flags & (os.O_WRONLY | os.O_RDWR):
            os.fchmod(fd, 0o600)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _midnight(day):
    return int(datetime(day.year, day.month, day.day).timestamp())


def _local_day(at):
    return datetime.fromtimestamp(at).date()


def prune(root, today):
    """Delete day files more than KEEP_DAYS days before today."""
    oldest = today - timedelta(days=KEEP_DAYS)
    for path in Path(root).iterdir():
        match = DAY_FILE.match(path.name)
        if not match or path.is_symlink() or not path.is_file():
            continue
        try:
            day = date.fromisoformat(match.group(1))
        except ValueError:
            continue
        if day < oldest:
            with contextlib.suppress(FileNotFoundError):
                path.unlink()


def _config(config_path):
    try:
        from hermes_cli.config import read_user_config_raw
        config = read_user_config_raw(config_path)
    except Exception:
        try:
            import yaml
            config = yaml.safe_load(Path(config_path).read_text())
        except Exception:
            return {}
    return config if isinstance(config, dict) else {}


def _search_backend(config):
    """The bot's web search service, best effort: ``web.search_backend``, else ``web.backend``."""
    web = config.get("web") if isinstance(config, dict) else None
    if not isinstance(web, dict):
        return ""
    for key in ("search_backend", "backend"):
        name = str(web.get(key) or "").strip().lower()
        if name and name != "auto" and SERVICE_NAME.match(name):
            return name
    return ""


def _backups(config):
    """(main provider, backup providers) from the bot's config: ``model.provider``, then each
    ``fallback_providers`` entry and the older ``fallback_model``."""
    model = config.get("model") if isinstance(config, dict) else None
    main = str(model.get("provider") or "").strip().lower() if isinstance(model, dict) else ""
    chain = config.get("fallback_providers") if isinstance(config, dict) else None
    chain = list(chain) if isinstance(chain, list) else []
    if isinstance(config, dict) and isinstance(config.get("fallback_model"), dict):
        chain.append(config["fallback_model"])
    backups = {str(item.get("provider") or "").strip().lower() for item in chain if isinstance(item, dict)}
    return main, frozenset(backups - {"", main})


def hermes_context(ctx):
    """What started the work a hook fires in, from Hermes's run context. No file is read.

    A schedule's run (``ctx.current_cron_execution()``), a Board worker (``HERMES_KANBAN_TASK``), a helper a
    schedule started (``HERMES_CRON_SESSION``), else a chat, with the chat app it came from when Hermes says.
    """
    def session_env(name):
        try:
            from gateway.session_context import get_session_env
            return str(get_session_env(name) or "")
        except Exception:
            return str(os.environ.get(name) or "")

    def context():
        try:
            execution = ctx.current_cron_execution()
        except Exception:
            execution = None
        if execution is not None:
            return {"origin": "schedule", "job": _id(getattr(execution, "job_id", ""), 64)}
        board = os.environ.get("HERMES_KANBAN_TASK")
        if board:
            return {"origin": "board", "board": _id(board, 64)}
        if session_env("HERMES_CRON_SESSION").strip().lower() in ("1", "true", "yes"):
            return {"origin": "helper"}
        platform = (session_env("HERMES_SESSION_PLATFORM") or session_env("HERMES_SESSION_SOURCE")).strip().lower()
        return {"origin": "chat", "platform": platform if PLATFORM_NAME.match(platform) else ""}
    return context


_RECORDERS = weakref.WeakSet()


@atexit.register
def _flush_all():
    # Writers are daemon threads; a short run such as a cron job still gets its last lines down.
    for recorder in list(_RECORDERS):
        recorder.flush(LOCK_WAIT_SECONDS + 1)


class Recorder:
    """Appends Papertrail lines for one bot home. Hook callbacks never raise into Hermes.

    A hook only builds its line and hands it to one writer thread, so Hermes gets its callback
    back at once and never skips the next one while this one waits on the file lock.
    ``is_private`` is asked before every line; when it says yes, or cannot say, nothing is written.
    """

    def __init__(self, home, *, clock=time.time, is_private=None, context=None):
        self.home = Path(home)
        self.root = self.home / "nollie-workflow" / "papertrail"
        self.clock = clock
        self.is_private = is_private
        # What started the work (``hermes_context``). Without it lines say nothing of why, as before.
        self.context = context
        self._pruned_on = None
        self._config = None
        self._guard = threading.Lock()
        self._waiting = deque()
        self._writer = None
        _RECORDERS.add(self)
        with contextlib.suppress(Exception):
            self._folder()

    # Hermes hooks. Keyword arguments only; Hermes adds fields over time, so the rest is ignored.

    def post_api_request(self, session_id="", turn_id="", model="", provider="", base_url="", ended_at=None,
                         usage=None, platform="", message_count=None, **_):
        self._safely(self._call, "model", "", provider, base_url, model, turn_id, session_id, ended_at, usage,
                     platform, message_count)

    def api_request_error(self, session_id="", turn_id="", model="", provider="", base_url="", ended_at=None,
                          platform="", message_count=None, **_):
        # The request still went out, so it is listed, without tokens.
        self._safely(self._call, "model", "", provider, base_url, model, turn_id, session_id, ended_at, None,
                     platform, message_count)

    def post_auxiliary_call(self, session_id="", turn_id="", aux_task="", model="", provider="", base_url="",
                            ended_at=None, usage=None, **_):
        self._safely(self._call, "helper", aux_task, provider, base_url, model, turn_id, session_id, ended_at, usage)

    def post_tool_call(self, tool_name="", args=None, status="", session_id="", turn_id="", result=None, **_):
        self._safely(self._tool, tool_name, args, status, turn_id, session_id, result)

    def post_approval_response(self, choice="", pattern_key="", pattern_keys=None, session_id="", turn_id="",
                               session_key="", **_):
        self._safely(self._approval, choice, pattern_key, pattern_keys, turn_id, session_id or session_key)

    # Away from home through iCloud. Not a Hermes hook: the Mac app reports it through the add-on.

    def icloud(self, kind, session=""):
        """One note sealed for the person's linked iPhone and put in their own iCloud. False for an unknown kind."""
        if kind not in AWAY_KINDS:
            return False
        self._safely(lambda: self._line(route="icloud", source="away", tool=kind, session=_id(session), origin="chat"))
        return True

    # Using this Mac. Not a Hermes hook: the Mac app reports it through the add-on when a task ends.

    def mac_session(self, apps, actions, looks=0, session=""):
        """One time a bot used apps on this Mac: their names, how many actions and looks. False when unreadable."""
        if not isinstance(apps, list) or not apps or isinstance(actions, bool) or not isinstance(actions, int):
            return False
        names = [APP_NAME.sub("", str(app))[:60].strip() for app in apps[:MAX_MAC_APPS] if isinstance(app, str)]
        names = [name for name in names if name]
        if not names:
            return False
        self._safely(lambda: self._line(route="mac", source="tool", tool=MAC_SESSION, session=_id(session),
                                        apps=names, actions=_count(actions), looks=_count(looks), screenshots_left=0))
        return True

    # Lines.

    def _line(self, **fields):
        line = {"v": 1, "at": round(self.clock(), 3), "route": "online", "source": "model", "provider": "",
                "host": None, "model": "", "task": "", "tool": "", "turn": "", "session": "",
                "in": 0, "out": 0, "cache": 0, "think": 0, "searches": 0, "pages": 0, "images": 0}
        if self.context is not None:
            try:
                found = self.context()
            except Exception:
                found = None
            if isinstance(found, dict) and found.get("origin") in ORIGINS:
                line["origin"] = found["origin"]
                for key in ("job", "board", "platform"):
                    if found.get(key):
                        line[key] = _id(found[key], 64)
        line.update(fields)
        return line

    def _call(self, source, task, provider, base_url, model, turn, session, ended_at, usage, platform="",
              message_count=None):
        usage = usage if isinstance(usage, dict) else {}
        line = self._line(at=_when(ended_at, self.clock), route=route(provider, base_url), source=source,
                          provider=_id(provider), host=host(base_url), model=_id(model), task=_id(task, 64),
                          turn=_id(turn), session=_id(session),
                          **{short: _count(usage.get(name)) for short, name in TOKEN_FIELDS})
        if "origin" not in line:
            return line
        if source == "model":
            # How much of the chat went with the request: a count, never the messages.
            line["messages"] = _count(message_count)
            platform = str(platform or "").strip().lower()
            if line["origin"] == "chat" and not line.get("platform") and PLATFORM_NAME.match(platform):
                line["platform"] = platform
            main, backups = self.models()
            name = str(provider or "").strip().lower()
            line["backup"] = bool(name) and name != main and name in backups
        return line

    def _approval(self, choice, pattern_key, pattern_keys, turn, session):
        """A person's answer in a turn, for that turn's Why. Only real answers, and only inside a turn: a
        timeout or a withdrawn question decided nothing, and without a turn it belongs to no entry."""
        choice = str(choice or "")
        if choice not in CHOICES or not turn:
            return None
        ask = ""
        for key in [pattern_key] + list(pattern_keys or []):
            if isinstance(key, str) and key.startswith(ASK_PREFIX):
                kind = key[len(ASK_PREFIX):].split(":", 1)[0]
                ask = kind if kind in ASK_KINDS else ""
                break
        return self._line(route="mac", source="approval", choice=choice, ask=ask, turn=_id(turn),
                          session=_id(session))

    def _tool(self, tool_name, args, status, turn, session, result=None):
        name = str(tool_name or "")
        if name == PAYMENT_TOOL:
            return self._payment(args, status, turn, session, result)
        if name in LOCAL_READS and status != "blocked":
            # The Mac's calendar, reminders or contacts, read in place. It stays here; what the model then
            # sends is the turn's own model call.
            return self._line(route="mac", source="tool", tool=name, turn=_id(turn), session=_id(session))
        if status == "blocked" or name not in SEARCH_TOOLS | PAGE_TOOLS | IMAGE_TOOLS:
            return None  # A blocked call sent nothing; other tools are not online services.
        pages = 0
        if name == "web_extract":
            urls = args.get("urls") if isinstance(args, dict) else None
            pages = min(len(urls), EXTRACT_MAX_URLS) if isinstance(urls, list) else 0
            if not pages:
                return None  # Hermes reads nothing without a list of URLs.
        elif name in PAGE_TOOLS:
            pages = 1
        service = "xai" if name == "x_search" else self.search_service() if name == "web_search" else ""
        # Search memo hits are counted too: over-reporting beats hiding a call.
        return self._line(route="online", source="tool", provider=service, tool=name, turn=_id(turn),
                          session=_id(session), searches=int(name in SEARCH_TOOLS), pages=pages,
                          images=int(name in IMAGE_TOOLS))

    def _payment(self, args, status, turn, session, result):
        """A card filled in and sent to a site: the site and the card's last four digits, nothing else."""
        if status == "blocked":
            return None
        try:
            answer = json.loads(result) if isinstance(result, str) else result
        except ValueError:
            return None
        if not isinstance(answer, dict) or answer.get("status") != "paid":
            return None
        site = normalize_site((args or {}).get("site") if isinstance(args, dict) else None)
        card = PAID_CARD.search(str(answer.get("card") or ""))
        if site is None:
            return None
        return self._line(route="online", source="tool", tool=PAYMENT_TOOL, host=site, turn=_id(turn),
                          session=_id(session), paid=1, card=card.group(1) if card else "")

    def _settings(self):
        """The bot's config.yaml, read lazily and cached until it changes."""
        path = self.home / "config.yaml"
        try:
            info = path.stat()
            signature = (info.st_mtime_ns, info.st_size, info.st_ino)
        except OSError:
            signature = None
        if self._config is None or self._config[0] != signature:
            self._config = (signature, _config(path) if signature else {})
        return self._config[1]

    def search_service(self):
        return _search_backend(self._settings())

    def models(self):
        """(main provider, backup providers), as the bot's config says now."""
        return _backups(self._settings())

    # Storage.

    def _safely(self, build, *args):
        try:
            line = build(*args)
            if line is not None:
                self._hand_off(line)
        except Exception as exc:
            self._note(exc)

    def _hand_off(self, line):
        with self._guard:
            if len(self._waiting) >= MAX_WAITING:
                raise OverflowError("too many Papertrail lines waiting")
            self._waiting.append(line)
            if self._writer is not None:
                return
            self._writer = writer = threading.Thread(target=self._drain, name="papertrail-writer", daemon=True)
        try:
            writer.start()
        except RuntimeError:
            # No new threads while Python shuts down: write on this thread instead.
            with self._guard:
                if self._writer is writer:
                    self._writer = None
            self._drain()

    def _drain(self):
        while True:
            with self._guard:
                if not self._waiting:
                    if self._writer is threading.current_thread():
                        self._writer = None
                    return
                line = self._waiting.popleft()
            try:
                allowed = self.is_private is None or not self.is_private()
            except Exception:
                allowed = False  # An unreadable Private list keeps the bot unrecorded.
            if not allowed:
                continue
            try:
                self.write(line)
            except Exception as exc:
                self._note(exc)

    def flush(self, timeout=5.0):
        """Wait for lines already handed off to be written. True when none are left waiting."""
        deadline = time.monotonic() + timeout
        while True:
            with self._guard:
                writer = self._writer
            if writer is None:
                return True
            left = deadline - time.monotonic()
            if writer is threading.current_thread() or left <= 0:
                return False
            try:
                writer.join(left)
            except RuntimeError:
                time.sleep(0.001)  # Handed off a moment ago and not started yet.

    def _folder(self):
        parent = self.root.parent
        if parent.is_symlink() or self.root.is_symlink():
            raise LinkedPath("the Papertrail folder is a link")
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.root.mkdir(mode=0o700, exist_ok=True)
        if self.root.is_symlink() or not self.root.is_dir():
            raise LinkedPath("the Papertrail folder is a link")
        os.chmod(self.root, 0o700)
        return self.root

    def _lock(self, fd):
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.01)

    def write(self, line):
        """Append one line under the folder lock. Raises; hooks go through ``_safely``."""
        root = self._folder()
        data = (json.dumps(line, separators=(",", ":"), allow_nan=False) + "\n").encode()
        lock = _open(root / "papertrail.lock", os.O_RDWR | os.O_CREAT)
        try:
            self._lock(lock)
            today = _local_day(self.clock())
            if self._pruned_on != today:
                prune(root, today)
                self._pruned_on = today
            fd = _open(root / f"{_local_day(line['at']).isoformat()}.jsonl", os.O_RDWR | os.O_APPEND | os.O_CREAT)
            try:
                size = os.fstat(fd).st_size
                if size and os.pread(fd, 1, size - 1) != b"\n":
                    data = b"\n" + data  # A torn last line stays torn; this one starts clean.
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
            finally:
                os.close(fd)
        finally:
            os.close(lock)

    def _note(self, exc):
        # The failure type only, never its message: messages can carry paths or text.
        with contextlib.suppress(Exception):
            if self.root.parent.is_symlink() or self.root.is_symlink() or not self.root.is_dir():
                return
            fd = _open(self.root / "last_error", os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
            try:
                os.write(fd, (type(exc).__name__[:64] + "\n").encode())
            finally:
                os.close(fd)


# Reading.

def _calls(path, since):
    try:
        fd = _open(path, os.O_RDONLY)
    except OSError:
        return
    with os.fdopen(fd, "rb") as handle:
        for raw in handle:
            try:
                line = json.loads(raw)
            except ValueError:
                continue  # A damaged or torn line is skipped, never fatal.
            if (not isinstance(line, dict) or line.get("v") != 1 or line.get("route") not in ROUTES
                    or line.get("source") not in SOURCES):
                continue
            at = line.get("at")
            if isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at) or at < since:
                continue
            call = {key: line.get(key) if isinstance(line.get(key), str) else ""
                    for key in ("provider", "model", "task", "tool", "turn", "session", "job", "board", "platform",
                                "choice", "ask")}
            if line["source"] == "door":
                host_, port = line.get("host"), line.get("port")
                if (not isinstance(host_, str) or not DOOR_HOST.match(host_) or isinstance(port, bool)
                        or not isinstance(port, int) or not 0 < port < 65536 or line["route"] == "mac"):
                    continue
                call.update(kind=line.get("kind") if line.get("kind") in DOOR_KINDS else "program", port=port,
                            turn="", session="")
            call.update({key: _count(line.get(key))
                         for key in ("in", "out", "cache", "think", "searches", "pages", "images", "messages")})
            call.update(at=float(at), route=line["route"], source=line["source"],
                        host=line.get("host") if isinstance(line.get("host"), str) else None,
                        origin=line.get("origin") if line.get("origin") in ORIGINS else None,
                        backup=line.get("backup") is True)
            if call["source"] == "approval" and (call["choice"] not in CHOICES or not call["turn"]):
                continue
            card = line.get("card")
            call.update(paid=_count(line.get("paid")),
                        card=card if isinstance(card, str) and re.fullmatch(r"[0-9]{4}", card) else "")
            if call["tool"] == MAC_SESSION:
                apps = line.get("apps")
                call.update(apps=[app[:60] for app in apps[:MAX_MAC_APPS] if isinstance(app, str)] if isinstance(apps, list) else [],
                            actions=_count(line.get("actions")), looks=_count(line.get("looks")))
            yield call


def _hermes_provider_name(provider):
    try:
        from hermes_cli.providers import get_provider
        found = get_provider(provider, allow_network=False)
    except Exception:
        return None
    name = getattr(found, "name", None)
    if not isinstance(name, str) or not name.strip() or name.strip() == str(provider):
        return None  # An echo of the id is not a display name; the app has its own labels.
    return name.strip()[:80]


def _tokens(call):
    return call["in"] + call["out"] + call["cache"] + call["think"]


def _why(group, left, titles):
    """Why the entry went, from what its lines kept; None when none of them kept it (recorded before 1.1)."""
    origins = [call for call in group if call.get("origin") in ORIGINS]
    if not origins:
        return None
    # The work that started it: a schedule or Board task over a helper, over a chat.
    first = min(origins, key=lambda call: (("schedule", "board", "helper", "chat").index(call["origin"]), call["at"]))
    origin = first["origin"]
    ref = first.get("job") if origin == "schedule" else first.get("board") if origin == "board" else ""
    title = (titles or {}).get((origin, ref)) if ref else None
    models = [call for call in left if call["source"] == "model"]
    approvals = sorted((call for call in group if call["source"] == "approval"), key=lambda call: call["at"])
    return {
        "origin": origin,
        "task": title or None,
        "platform": next((call.get("platform") for call in origins
                          if call["origin"] == "chat" and call.get("platform")), None),
        # The most messages any one request carried: each request sends the chat so far.
        "messages": max((call.get("messages", 0) for call in models), default=0),
        "backup": any(call.get("backup") for call in models),
        "approvals": [{"at": int(call["at"]), "choice": call.get("choice"),
                       "ask": call.get("ask") if call.get("ask") in ASK_KINDS else None}
                      for call in approvals[-MAX_APPROVALS:]],
    }


def _entry(key, group, provider_name, titles=None):
    """An entry for what left; None when every call stayed on this Mac."""
    left = [call for call in group if call["route"] != "mac"]
    if not left:
        return None
    routes = {}
    for call in left:
        if call["source"] not in ("tool", "door"):
            totals = routes.setdefault((call["route"], call["provider"], call["host"], call["model"]), [0, 0])
            totals[0] += _tokens(call)
            totals[1] += 1
    # The entry's largest online model route by tokens; a network route only when nothing went online,
    # so a network model beside an online search is named by the search, not the network host.
    went_online = any(call["route"] == "online" for call in left)
    candidates = {k: v for k, v in routes.items() if k[0] == ("online" if went_online else "network")}
    best = max(candidates, key=lambda k: (candidates[k], [str(part or "") for part in k]), default=None)
    _, provider, host_, model = best if best else (None, None, None, None)
    provider = provider or None
    entry = {
        "id": key[1] if key[0] == "turn" else "w-" + hashlib.sha256(json.dumps(key).encode()).hexdigest()[:16],
        "at": int(max(call["at"] for call in group)),
        "started_at": int(min(call["at"] for call in group)),
        "route": "online" if went_online else "network" if any(call["route"] == "network" for call in left) else "icloud",
        "provider": provider,
        "provider_name": provider_name(provider) if provider else None,
        "host": host_,
        "model": model or None,
        "calls": sum(call["source"] != "door" for call in left),
        "helpers": sorted({call["task"] for call in left if call["source"] == "helper" and call["task"]}),
        "services": sorted({call["provider"] for call in left
                            if call["source"] == "tool" and call["searches"] and call["provider"]}),
        "input_tokens": sum(call["in"] for call in left),
        "output_tokens": sum(call["out"] for call in left),
        "cache_read_tokens": sum(call["cache"] for call in left),
        "reasoning_tokens": sum(call["think"] for call in left),
        "searches": sum(call["searches"] for call in left),
        "pages": sum(call["pages"] for call in left),
        "images": sum(call["images"] for call in left),
        # Notes sealed for the person's own iPhone and put in their iCloud, while they were away.
        "icloud_notes": sum(call["route"] == "icloud" for call in left),
        # Cards filled in and sent to a site: the site and the card's last four digits only.
        "payments": [{"site": call["host"], "card": call["card"] or None} for call in left
                     if call["source"] == "tool" and call["paid"] and call["host"]],
        # What the turn read on this Mac before its words went out: "calendar", "reminders", "contacts".
        "local_reads": sorted({LOCAL_READS[call["tool"]] for call in group
                               if call["source"] == "tool" and call["tool"] in LOCAL_READS}),
        # Every connection the door saw in it: where to, by which kind of program, how many times.
        "connections": _connections(left),
    }
    why = _why(group, left, titles)
    if why is not None:
        entry["why"] = why
    return entry


def _connections(calls):
    found = {}
    for call in calls:
        if call["source"] == "door":
            key = (call["host"], call["port"], call["kind"])
            found.setdefault(key, {"host": call["host"], "port": call["port"], "kind": call["kind"],
                                   "route": call["route"], "count": 0})["count"] += 1
    return sorted(found.values(), key=lambda item: (-item["count"], item["host"], item["port"], item["kind"]))


def _place_doors(groups, doors):
    """Each door connection into the reply it happened in (the group whose own calls span its time, with a
    few seconds either side; the latest-starting when several do), else into its hour."""
    spans = []
    for key, group in groups.items():
        if all(call["source"] == "approval" for call in group):
            continue
        times = [call["at"] for call in group]
        spans.append((min(times) - DOOR_SLACK, max(times) + DOOR_SLACK, key))
    spans.sort(key=lambda span: span[0])
    for call in doors:
        inside = [span for span in spans if span[0] <= call["at"] <= span[1]]
        key = max(inside, key=lambda span: span[0])[2] if inside else ("door", int(call["at"] // DOOR_WINDOW))
        groups.setdefault(key, []).append(call)


def read(home, bot, days, *, now=None, provider_name=None, titles=None):
    """The Papertrail answer for one bot home over ``days`` local days ending today. ``titles`` maps
    ``("schedule", job id)`` and ``("board", task id)`` to the names the person gave them, read now, never
    kept in the record."""
    root = Path(home) / "nollie-workflow" / "papertrail"
    now = time.time() if now is None else now
    today = _local_day(now)
    first = today - timedelta(days=days - 1)
    today_starts_at, since = _midnight(today), _midnight(first)
    calls, oldest = [], None
    if root.is_dir() and not root.is_symlink():
        for path in sorted(root.iterdir()):
            match = DAY_FILE.match(path.name)
            if not match or path.is_symlink() or not path.is_file():
                continue
            try:
                day = date.fromisoformat(match.group(1))
            except ValueError:
                continue
            oldest = day if oldest is None or day < oldest else oldest
            if first <= day <= today:
                calls.extend(_calls(path, since))
    groups = {}
    doors = [call for call in calls if call["source"] == "door"]
    calls = [call for call in calls if call["source"] != "door"]
    for call in calls:
        # One entry per turn. Calls outside a turn group by session, route and a 10 minute window.
        key = (("turn", call["turn"]) if call["turn"]
               else ("window", call["session"], call["route"], int(call["at"] // WINDOW_SECONDS)))
        groups.setdefault(key, []).append(call)
    _place_doors(groups, doors)
    names = {}

    def cached_name(provider):
        if provider not in names:
            names[provider] = (provider_name or _hermes_provider_name)(provider)
        return names[provider]

    # Each time the bot used this Mac, newest first: it all stayed here, so it is listed apart from what left.
    mac_sessions = sorted(({"at": int(call["at"]), "apps": call["apps"], "actions": call["actions"],
                            "looks": call["looks"], "screenshots_left": 0}
                           for call in calls if call["source"] == "tool" and call["tool"] == MAC_SESSION
                           and call["route"] == "mac"), key=lambda session: session["at"], reverse=True)
    stayed = {"today": 0, "window": 0}
    entries = []
    for key, group in groups.items():
        if all(call["source"] == "approval" for call in group):
            continue  # An answer alone is not a reply: it only explains one.
        entry = _entry(key, group, cached_name, titles)
        if entry is None:
            stayed["window"] += 1
            stayed["today"] += max(call["at"] for call in group) >= today_starts_at
        else:
            entries.append(entry)
    entries.sort(key=lambda entry: (entry["at"], entry["id"]), reverse=True)
    left_today = sum(entry["at"] >= today_starts_at for entry in entries)
    return {
        "bot": bot,
        "days": days,
        "now": int(now),
        "today_starts_at": today_starts_at,
        "tomorrow_starts_at": _midnight(today + timedelta(days=1)),
        "since": since,
        "recording_since": _midnight(oldest) if oldest else None,
        "stayed": stayed,
        "left": {"today": left_today, "window": len(entries)},
        "entries": entries[:MAX_ENTRIES],
        "more": max(0, len(entries) - MAX_ENTRIES),
        "mac_sessions": mac_sessions[:MAX_MAC_SESSIONS],
    }
