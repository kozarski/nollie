"""Papertrail: a wordless record of what one bot sent off this Mac.

One JSON line per model call, helper call or online tool, kept in the bot's own home under
``nollie-workflow/papertrail/<YYYY-MM-DD>.jsonl``. Only when, where and how much: never prompts,
replies, queries, URLs or arguments. Stdlib only here; Hermes is imported lazily and best effort.
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

KEEP_DAYS = 35
MAX_ENTRIES = 200
WINDOW_SECONDS = 600
LOCK_WAIT_SECONDS = 2.0
MAX_WAITING = 5000
HOOKS = ("post_api_request", "api_request_error", "post_auxiliary_call", "post_tool_call")
ROUTES = frozenset({"mac", "network", "online"})
SOURCES = frozenset({"model", "helper", "tool"})
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
HOST_TEXT = re.compile(r"[A-Za-z0-9._:%\[\]-]{1,255}\Z")
UNSAFE_ID = re.compile(r"[^A-Za-z0-9._:/@+=-]")
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


def _search_backend(config_path):
    """The bot's web search service, best effort: ``web.search_backend``, else ``web.backend``."""
    try:
        from hermes_cli.config import read_user_config_raw
        config = read_user_config_raw(config_path)
    except Exception:
        try:
            import yaml
            config = yaml.safe_load(Path(config_path).read_text())
        except Exception:
            return ""
    web = config.get("web") if isinstance(config, dict) else None
    if not isinstance(web, dict):
        return ""
    for key in ("search_backend", "backend"):
        name = str(web.get(key) or "").strip().lower()
        if name and name != "auto" and SERVICE_NAME.match(name):
            return name
    return ""


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

    def __init__(self, home, *, clock=time.time, is_private=None):
        self.home = Path(home)
        self.root = self.home / "nollie-workflow" / "papertrail"
        self.clock = clock
        self.is_private = is_private
        self._pruned_on = None
        self._service = None
        self._guard = threading.Lock()
        self._waiting = deque()
        self._writer = None
        _RECORDERS.add(self)
        with contextlib.suppress(Exception):
            self._folder()

    # Hermes hooks. Keyword arguments only; Hermes adds fields over time, so the rest is ignored.

    def post_api_request(self, session_id="", turn_id="", model="", provider="", base_url="", ended_at=None,
                         usage=None, **_):
        self._safely(self._call, "model", "", provider, base_url, model, turn_id, session_id, ended_at, usage)

    def api_request_error(self, session_id="", turn_id="", model="", provider="", base_url="", ended_at=None, **_):
        # The request still went out, so it is listed, without tokens.
        self._safely(self._call, "model", "", provider, base_url, model, turn_id, session_id, ended_at, None)

    def post_auxiliary_call(self, session_id="", turn_id="", aux_task="", model="", provider="", base_url="",
                            ended_at=None, usage=None, **_):
        self._safely(self._call, "helper", aux_task, provider, base_url, model, turn_id, session_id, ended_at, usage)

    def post_tool_call(self, tool_name="", args=None, status="", session_id="", turn_id="", **_):
        self._safely(self._tool, tool_name, args, status, turn_id, session_id)

    # Lines.

    def _line(self, **fields):
        line = {"v": 1, "at": round(self.clock(), 3), "route": "online", "source": "model", "provider": "",
                "host": None, "model": "", "task": "", "tool": "", "turn": "", "session": "",
                "in": 0, "out": 0, "cache": 0, "think": 0, "searches": 0, "pages": 0, "images": 0}
        line.update(fields)
        return line

    def _call(self, source, task, provider, base_url, model, turn, session, ended_at, usage):
        usage = usage if isinstance(usage, dict) else {}
        return self._line(at=_when(ended_at, self.clock), route=route(provider, base_url), source=source,
                          provider=_id(provider), host=host(base_url), model=_id(model), task=_id(task, 64),
                          turn=_id(turn), session=_id(session),
                          **{short: _count(usage.get(name)) for short, name in TOKEN_FIELDS})

    def _tool(self, tool_name, args, status, turn, session):
        name = str(tool_name or "")
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

    def search_service(self):
        """Read lazily and cached until the bot's config.yaml changes."""
        path = self.home / "config.yaml"
        try:
            info = path.stat()
            signature = (info.st_mtime_ns, info.st_size, info.st_ino)
        except OSError:
            signature = None
        if self._service is None or self._service[0] != signature:
            self._service = (signature, _search_backend(path) if signature else "")
        return self._service[1]

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
                    for key in ("provider", "model", "task", "tool", "turn", "session")}
            call.update({key: _count(line.get(key))
                         for key in ("in", "out", "cache", "think", "searches", "pages", "images")})
            call.update(at=float(at), route=line["route"], source=line["source"],
                        host=line.get("host") if isinstance(line.get("host"), str) else None)
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


def _entry(key, group, provider_name):
    """An entry for what left; None when every call stayed on this Mac."""
    left = [call for call in group if call["route"] != "mac"]
    if not left:
        return None
    routes = {}
    for call in left:
        if call["source"] != "tool":
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
    return {
        "id": key[1] if key[0] == "turn" else "w-" + hashlib.sha256(json.dumps(key).encode()).hexdigest()[:16],
        "at": int(max(call["at"] for call in group)),
        "started_at": int(min(call["at"] for call in group)),
        "route": "online" if went_online else "network",
        "provider": provider,
        "provider_name": provider_name(provider) if provider else None,
        "host": host_,
        "model": model or None,
        "calls": len(left),
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
        # What the turn read on this Mac before its words went out: "calendar", "reminders", "contacts".
        "local_reads": sorted({LOCAL_READS[call["tool"]] for call in group
                               if call["source"] == "tool" and call["tool"] in LOCAL_READS}),
    }


def read(home, bot, days, *, now=None, provider_name=None):
    """The Papertrail answer for one bot home over ``days`` local days ending today."""
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
    for call in calls:
        # One entry per turn. Calls outside a turn group by session, route and a 10 minute window.
        key = (("turn", call["turn"]) if call["turn"]
               else ("window", call["session"], call["route"], int(call["at"] // WINDOW_SECONDS)))
        groups.setdefault(key, []).append(call)
    names = {}

    def cached_name(provider):
        if provider not in names:
            names[provider] = (provider_name or _hermes_provider_name)(provider)
        return names[provider]

    stayed = {"today": 0, "window": 0}
    entries = []
    for key, group in groups.items():
        entry = _entry(key, group, cached_name)
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
    }
