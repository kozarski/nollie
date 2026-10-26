"""Session-scoped, read-only previews. This module never opens a session database."""
from __future__ import annotations

import asyncio
import base64
import binascii
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import time

MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_MESSAGE_BYTES = 6 * 1024 * 1024
CAPTURE_TIMEOUT = 5.0
IDLE_SECONDS = 15.0
RECHECK_SECONDS = 30.0
MAX_CHILDREN = 4
SPACE_TARGET = re.compile(r"(local|cloud):([A-Za-z0-9][A-Za-z0-9_.-]{0,127})\Z")
BARE_TARGET = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\Z")
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
COMPUTER_TOOLS = {
    "computer_screenshot", "computer_click", "computer_double_click", "computer_right_click",
    "computer_move", "computer_move_cursor", "computer_mouse_down", "computer_mouse_up",
    "computer_drag", "computer_scroll", "computer_type", "computer_key",
    "computer_keypress", "computer_press_key", "computer_hotkey",
}
# Cua's documented position arguments, in the pixel space of the last computer_screenshot
# (cua.ai/docs/cua-cli/reference/mcp-tools). A drag ends where it lets go.
POINTER_TOOLS = {
    "computer_click": ("x", "y"), "computer_double_click": ("x", "y"), "computer_right_click": ("x", "y"),
    "computer_move_cursor": ("x", "y"), "computer_mouse_down": ("x", "y"), "computer_mouse_up": ("x", "y"),
    "computer_drag": ("end_x", "end_y"),
}
MAX_COORDINATE = 8192
MAC_DISCOVERY = {"list", "list_apps", "list_windows", "list_displays", "list_spaces", "info",
                 "status", "get_info", "get_status", "help", "doctor", "permissions", "get_permissions"}
# Saved sign-ins (nollie-workflow): while one is typed, and SETTLE seconds after, no frame is shown.
SIGN_IN_TYPING = ("approved", "filling")
SIGN_IN_STATES = ("asking", "approved", "filling", "done")
SIGN_IN_LIFETIME = 3600
SIGN_IN_SETTLE = 10.0
# Saved cards (nollie-workflow's payments.py) pause pictures the same way while a card number may show.
PAYMENT_TYPING = ("filling", "showing")
PAYMENT_STATES = ("waiting", "prepared", "approved", "filling", "showing", "done")
PAUSED = "Paused while Nollie types a saved sign-in."


def _load_private_bots():
    spec = importlib.util.spec_from_file_location("nollie_computer_private_bots",
                                                  Path(__file__).with_name("private_bots.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


private_bots = _load_private_bots()


def main_home():
    """The main bot's Hermes home, where Nollie keeps the Private list."""
    from hermes_cli.profiles import get_profile_dir
    return Path(get_profile_dir("default"))


def private_names():
    return private_bots.read(main_home())[0]


def sign_in_typing(home, now):
    """True while a saved sign-in or card may be on a screen, by the same rules as nollie-workflow's typing_now.

    A request being typed (and not past its lifetime), one finished less than SETTLE ago, a damaged
    recent request file and a linked folder all count. Fails closed."""
    workflow = Path(home) / "nollie-workflow"
    return (_typing_in(workflow / "sign-ins", SIGN_IN_STATES, SIGN_IN_TYPING, now)
            or _typing_in(workflow / "payments", PAYMENT_STATES, PAYMENT_TYPING, now))


def _typing_in(root, states, typing, now):
    folder = root / "requests"
    try:
        if root.is_symlink() or folder.is_symlink():
            return True
        paths = list(folder.glob("*.json")) if folder.is_dir() else []
    except OSError:
        return True
    for path in paths:
        try:
            record = json.loads(path.read_text())
            state, created, updated = record.get("state"), record.get("created_at"), record.get("updated_at")
            if type(created) is not int or type(updated) is not int or state not in states:
                raise ValueError("damaged")
        except (OSError, ValueError, UnicodeDecodeError, AttributeError):
            try:
                if now - path.stat().st_mtime <= SIGN_IN_LIFETIME:
                    return True
            except OSError:
                pass
            continue
        if state in typing and now - created <= SIGN_IN_LIFETIME:
            return True
        if state == "done":
            quiet = record.get("quiet_until")
            # Seconds are whole in updated_at, so an older record without quiet_until gets one more.
            until = quiet if isinstance(quiet, (int, float)) and not isinstance(quiet, bool) else \
                updated + SIGN_IN_SETTLE + 1
            if now < until:
                return True
    return False


class PreviewUnavailable(Exception):
    """An expected failure with no remote error or secret attached."""


class SpaceMissing(PreviewUnavailable):
    """The exact Space lookup returned Cua's structured not_found result."""


def decode_object(value):
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except (ValueError, TypeError):
            return None
    return value if isinstance(value, dict) else None


def successful(value, depth=0):
    """Require affirmative tool evidence, not the mere absence of an error."""
    if depth > 8:
        return False
    if isinstance(value, str) and value.startswith('<untrusted_tool_result source="'):
        # Hermes adds this data boundary and a one-paragraph notice to stored MCP results.
        # Only parse its JSON payload; the notice and any following text are never instructions.
        wrapped = re.match(r'\A<untrusted_tool_result source="[A-Za-z0-9_:.\-]+">\n[^\n]*\n\n(.*?)\n</untrusted_tool_result>', value, re.S)
        if not wrapped:
            return False
        value = wrapped[1]
    if isinstance(value, list):
        return any(isinstance(part, dict) and part.get("type") == "text"
                   and successful(part.get("text"), depth + 1) for part in value)
    obj = decode_object(value)
    if not obj:
        return False
    if obj.get("isError") is True or obj.get("success") is False or obj.get("ok") is False or obj.get("error"):
        return False
    if obj.get("success") is True or obj.get("ok") is True or obj.get("screenshot_path"):
        return True
    result = obj.get("result")
    if isinstance(result, str) and re.search(r"MEDIA:(?:/|~/)[^\s]+\.(?:png|jpe?g|webp)\b", result, re.I):
        return True
    if successful(result, depth + 1) or successful(obj.get("structuredContent"), depth + 1):
        return True
    for part in obj.get("content", []):
        if isinstance(part, dict) and part.get("type") == "image" and part.get("data"):
            return True
        if isinstance(part, dict) and part.get("type") == "text" and successful(part.get("text"), depth + 1):
            return True
    return False


def underlying_call(function):
    name = function.get("name", "")
    args = decode_object(function.get("arguments"))
    if args is None:
        return None
    if name == "tool_call":
        entries = args.get("calls", [{"name": args.get("name"), "arguments": args.get("arguments")}])
        if isinstance(entries, str):
            try:
                entries = json.loads(entries)
            except ValueError:
                return None
        if isinstance(entries, dict):
            entries = [entries]
        # Hermes permits one local tool per bridge invocation. A batch cannot select a target.
        if not isinstance(entries, list) or len(entries) != 1 or not isinstance(entries[0], dict):
            return None
        name, args = entries[0].get("name", ""), decode_object(entries[0].get("arguments"))
    return (name, args) if isinstance(name, str) and args is not None else None


def completed_space_command(value):
    """Cua stores bash stdout as a plain result, without a success or exit-code field."""
    if isinstance(value, str) and value.startswith('<untrusted_tool_result source="'):
        wrapped = re.match(r'\A<untrusted_tool_result source="[A-Za-z0-9_:.\-]+">\n[^\n]*\n\n(.*?)\n</untrusted_tool_result>', value, re.S)
        value = wrapped[1] if wrapped else None
    obj = decode_object(value)
    return bool(obj is not None and isinstance(obj.get("result"), str)
                and obj.get("isError") is not True and obj.get("success") is not False
                and obj.get("ok") is not False and not obj.get("error"))


def pending_mac_call(messages):
    """An unfinished Mac call in the latest turn must not be replaced by a VM frame."""
    pending, seen = set(), set()
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role in ("user", "error") or role == "assistant" and not message.get("tool_calls"):
            pending.clear()
        if role == "assistant":
            for call in message.get("tool_calls") or []:
                if not isinstance(call, dict) or not isinstance(call.get("id"), str):
                    continue
                call_id = call["id"]
                if call_id in seen:
                    pending.discard(call_id)
                    continue
                seen.add(call_id)
                function = call.get("function")
                underlying = underlying_call(function) if isinstance(function, dict) else None
                if underlying and underlying[0] == "computer_use" and underlying[1].get("action") not in MAC_DISCOVERY:
                    pending.add(call_id)
        elif role == "tool":
            pending.discard(message.get("tool_call_id"))
    return bool(pending)


def read_owned_space(profile, path=None):
    """Read an explicit local ownership record, never discover a computer by listing VMs."""
    if not isinstance(profile, str) or not PROFILE_NAME.fullmatch(profile):
        return None
    path = path or Path.home() / ".hermes/nollie-computer/owned-spaces.json"
    try:
        # The Private list sits in the same Hermes home as the ownership record.
        if profile in private_bots.read(path.parent.parent)[0]:
            return None
        if path.is_symlink() or path.stat().st_size > 16384:
            return None
        document = json.loads(path.read_text())
        owners = document.get("profiles") if isinstance(document, dict) and document.get("version") == 1 else None
        target = owners.get(profile) if isinstance(owners, dict) else None
        return target if isinstance(target, str) and SPACE_TARGET.fullmatch(target) else None
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def pointer_of(name, args, message):
    """Where a successful Cua pointer action acted, from its own arguments. Never guessed."""
    keys = POINTER_TOOLS.get(name.removeprefix("mcp__cua__")) if name.startswith("mcp__cua__") else None
    if not keys:
        return None
    x, y = args.get(keys[0]), args.get(keys[1])
    if not all(type(v) is int and 0 <= v <= MAX_COORDINATE for v in (x, y)):
        return None
    pointer = {"x": x, "y": y}
    at = message.get("timestamp")
    if type(at) in (int, float) and at > 0:
        pointer["at"] = float(at)
    return pointer


def resolve_target(messages):
    """Only paired successful tool results establish a target; user text never does."""
    calls, seen_ids, target = {}, set(), None
    for message in messages:
        if not isinstance(message, dict):
            continue
        if message.get("role") == "assistant":
            for call in message.get("tool_calls") or []:
                if not isinstance(call, dict):
                    continue
                call_id = call.get("id")
                if not isinstance(call_id, str) or not call_id:
                    continue
                if call_id in seen_ids:
                    calls.pop(call_id, None)
                    continue
                seen_ids.add(call_id)
                if not isinstance(call.get("function"), dict):
                    continue
                underlying = underlying_call(call["function"])
                if underlying is not None:
                    calls[call_id] = underlying
        if message.get("role") != "tool":
            continue
        call_id = message.get("tool_call_id")
        # Consume each unique call once. Repeated results or reused bridge IDs cannot
        # replay an older computer after the session has moved to another target.
        name, args = calls.pop(call_id, ("", {})) if isinstance(call_id, str) else ("", {})
        if not (successful(message.get("content")) or name == "mcp__cua__space_bash"
                and completed_space_command(message.get("content"))):
            continue
        if message.get("tool_name") not in (None, "", name, "tool_call"):
            continue
        if name == "computer_use" and args.get("action") not in MAC_DISCOVERY:
            target = {"kind": "mac", "computer_name": "This Mac", "sandbox": None, "pointer": None}
        elif name.startswith("mcp__cua__") and (name.removeprefix("mcp__cua__") in COMPUTER_TOOLS or name == "mcp__cua__space_bash"):
            sandbox = args.get("space" if name == "mcp__cua__space_bash" else "sandbox")
            # Never guess a default target or open a client URL. Bare names are verified before capture.
            valid = isinstance(sandbox, str) and (SPACE_TARGET.fullmatch(sandbox)
                    or name != "mcp__cua__space_bash" and BARE_TARGET.fullmatch(sandbox))
            same = target is not None and valid and target["sandbox"] == sandbox
            # A new computer forgets the last one's pointer; a screenshot keeps it.
            pointer = pointer_of(name, args, message) if valid else None
            target = {"kind": "space", "computer_name": sandbox.split(":", 1)[-1] if valid else "Computer",
                      "sandbox": sandbox if valid else None,
                      "pointer": pointer or (target.get("pointer") if same else None)}
    return target


def image_data_url(result):
    if not isinstance(result, dict) or result.get("isError") or result.get("error"):
        raise PreviewUnavailable()
    for part in result.get("content", []):
        if not isinstance(part, dict) or part.get("type") != "image" or part.get("mimeType") != "image/png":
            continue
        data = part.get("data")
        if not isinstance(data, str) or len(data) > (MAX_IMAGE_BYTES + 2) // 3 * 4:
            raise PreviewUnavailable()
        try:
            decoded = base64.b64decode(data, validate=True)
        except (ValueError, binascii.Error):
            raise PreviewUnavailable() from None
        if not decoded.startswith(b"\x89PNG\r\n\x1a\n") or len(decoded) > MAX_IMAGE_BYTES:
            raise PreviewUnavailable()
        return "data:image/png;base64," + data
    raise PreviewUnavailable()


async def _response(process, request_id):
    for _ in range(32):
        line = await process.stdout.readline()
        if not line or len(line) > MAX_MESSAGE_BYTES:
            raise PreviewUnavailable()
        try:
            reply = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            raise PreviewUnavailable() from None
        if isinstance(reply, dict) and reply.get("id") == request_id:
            if reply.get("error") or not isinstance(reply.get("result"), dict):
                raise PreviewUnavailable()
            return reply["result"]
    raise PreviewUnavailable()


class CuaChild:
    """One Cua MCP child for one Space. It looks the Space up when opened, then takes pictures of that exact ID."""

    def __init__(self, process, clock=time.monotonic):
        self.process, self.clock = process, clock
        self.space, self.checked_at, self.timer = None, None, None
        self._next_id, self._initialized = 1, False

    async def _send(self, message):
        self.process.stdin.write((json.dumps({"jsonrpc": "2.0", **message}) + "\n").encode())
        await self.process.stdin.drain()

    async def _call(self, method, params):
        request_id, self._next_id = self._next_id, self._next_id + 1
        await self._send({"id": request_id, "method": method, "params": params})
        return await _response(self.process, request_id)

    async def _look_up(self, sandbox):
        info_result = await self._call("tools/call", {"name": "sandbox_get", "arguments": {"name": sandbox}})
        structured = info_result.get("structuredContent")
        if (info_result.get("isError") is True and isinstance(structured, dict)
                and isinstance(structured.get("error"), dict) and structured["error"].get("kind") == "not_found"):
            raise SpaceMissing()
        info = None
        if not info_result.get("isError"):
            for part in info_result.get("content", []):
                if isinstance(part, dict) and part.get("type") == "text":
                    candidate = decode_object(part.get("text"))
                    if candidate and "location" in candidate:
                        info = candidate
                        break
        resolved = SPACE_TARGET.fullmatch(info.get("id", "")) if info and isinstance(info.get("id"), str) else None
        if (not resolved or info.get("location") != resolved[1] or info.get("status") != "ready"
                or resolved[2] != sandbox.split(":", 1)[-1]
                or ":" in sandbox and info["id"] != sandbox):
            raise PreviewUnavailable()
        return info["id"]

    async def picture(self, sandbox):
        if not self._initialized:
            await self._call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                            "clientInfo": {"name": "nollie-computer", "version": "0.1.0"}})
            await self._send({"method": "notifications/initialized"})
            self._initialized = True
        # The lookup runs when the child opens and again every so often, never only once for its life.
        if self.space is None or self.clock() - self.checked_at >= RECHECK_SECONDS:
            self.space = None
            self.space = await self._look_up(sandbox)
            self.checked_at = self.clock()
        return image_data_url(await self._call("tools/call", {
            "name": "computer_screenshot", "arguments": {"sandbox": self.space}}))

    async def close(self):
        if self.timer:
            self.timer.cancel()
        await _stop(self.process)


async def _stop(process):
    if process.returncode is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            await asyncio.wait_for(process.wait(), 0.5)
        except TimeoutError:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            await process.wait()


async def spawn_cua():
    executable = shutil.which("cua")
    socket = Path.home() / ".cua" / "cua.sock"
    try:
        available = stat.S_ISSOCK(socket.stat().st_mode)
    except OSError:
        available = False
    if not executable or not available:
        raise PreviewUnavailable()
    # Explicit daemon mode only connects. Without it the CLI may start a daemon.
    return await asyncio.create_subprocess_exec(
        executable, "--daemon", str(socket), "mcp", "--permissions", "sandbox:get,computer:screenshot",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, limit=MAX_MESSAGE_BYTES,
        env={**os.environ, "CUA_TELEMETRY": "0"})


class CapturePool:
    """Keeps one Cua MCP child per Space between pictures, so a picture costs one tool call instead of
    a process start, a handshake and a lookup. Any error, timeout or cancellation closes the child."""

    def __init__(self, spawn=None, idle=IDLE_SECONDS, timeout=CAPTURE_TIMEOUT, limit=MAX_CHILDREN, clock=time.monotonic):
        self.spawn = spawn or spawn_cua
        self.idle, self.timeout, self.limit, self.clock = idle, timeout, limit, clock
        self._parked = {}  # Space -> child waiting for its next picture, least recently used first
        self._live = set()
        self._starting = 0  # children being started, counted against the limit before they exist
        self._closing = set()

    async def capture(self, sandbox):
        if not isinstance(sandbox, str) or not (SPACE_TARGET.fullmatch(sandbox) or BARE_TARGET.fullmatch(sandbox)):
            raise PreviewUnavailable()
        child = self._parked.pop(sandbox, None)
        if child is not None:
            child.timer.cancel()
            if child.process.returncode is not None:
                self._close_later(child)
                child = None
        try:
            if child is None:
                self._make_room()
                self._starting += 1
                try:
                    process = await asyncio.wait_for(self.spawn(), self.timeout)
                finally:
                    self._starting -= 1
                child = CuaChild(process, self.clock)
                self._live.add(child)
            data = await asyncio.wait_for(child.picture(sandbox), self.timeout)
        except BaseException:
            if child is not None:
                self._live.discard(child)
                await child.close()
            raise
        self._park(sandbox, child)
        return data

    def _make_room(self):
        while self._parked and len(self._live) + self._starting >= self.limit:
            self._close_later(self._parked.pop(next(iter(self._parked))))
        if len(self._live) + self._starting >= self.limit:
            raise PreviewUnavailable()

    def _park(self, sandbox, child):
        if sandbox in self._parked:
            # Two pictures of one Space ran at once; keep one child.
            self._close_later(child)
            return
        child.timer = asyncio.get_running_loop().call_later(self.idle, self._expire, sandbox, child)
        self._parked[sandbox] = child

    def _expire(self, sandbox, child):
        if self._parked.get(sandbox) is child:
            del self._parked[sandbox]
            self._close_later(child)

    def release(self, sandbox):
        """Closes the waiting child for a Space no chat is looking at any more."""
        child = self._parked.pop(sandbox, None)
        if child is not None:
            self._close_later(child)

    def _close_later(self, child):
        self._live.discard(child)
        if child.timer:
            child.timer.cancel()
        task = asyncio.get_running_loop().create_task(child.close())
        self._closing.add(task)
        task.add_done_callback(self._closing.discard)

    async def close(self):
        """At shutdown: closes every waiting child and waits for them to go."""
        for sandbox in list(self._parked):
            self.release(sandbox)
        if self._closing:
            await asyncio.gather(*self._closing, return_exceptions=True)

    def kill(self):
        """At exit, with no event loop left: asks every child still running to stop."""
        for child in list(self._live):
            if child.process.returncode is None:
                try:
                    os.kill(child.process.pid, signal.SIGTERM)
                except (OSError, AttributeError, TypeError):
                    pass


async def read_session(profile, session_id):
    # These public route helpers open only the requested profile store, read-only.
    from hermes_cli.web_routers.sessions import get_session_detail, get_session_messages
    detail = await get_session_detail(session_id=session_id, profile=profile)
    if (detail.get("id") != session_id or detail.get("profile") != profile
            or detail.get("profile_name") not in (None, "", profile) or detail.get("archived")):
        raise PreviewUnavailable()
    page = await get_session_messages(session_id=session_id, profile=profile, limit=500,
                                      offset=0, order="latest", include_compacted=False, inline_images=False)
    # A rotated chat needs its new exact ID; never silently broaden the requested scope.
    if page.get("session_id") != session_id or page.get("profile") != profile:
        raise PreviewUnavailable()
    return page.get("messages", [])


class Refused(PreviewUnavailable):
    """The bot became private while its picture was on the way."""


class Paused(PreviewUnavailable):
    """A saved sign-in may be on screen: no picture is taken, kept or handed out."""


REFUSED = {"state": "unavailable", "message": "This chat has no available computer preview."}
UNKNOWN = object()


class PreviewService:
    def __init__(self, reader=read_session, capture=None, clock=time.time, owned_reader=None,
                 private_reader=None, control_reader=None, pool=None, typing_reader=None):
        # Without an injected capture, pictures come from a pool of Cua children kept between calls.
        self.pool = pool or (CapturePool() if capture is None else None)
        self.reader, self.capture, self.clock = reader, capture or self.pool.capture, clock
        # Whether a saved sign-in may be on screen: asked before a capture or reuse and again after it.
        self.typing_reader = typing_reader or (lambda: sign_in_typing(main_home(), time.time()))
        # Who holds the computer ("helper", "you", "someone"); None leaves it out.
        self.control_reader = control_reader or (lambda _profile: None)
        self.owned_reader = owned_reader or read_owned_space
        self.private_reader = private_reader or private_names
        self._cache = {}
        self._flights = {}  # Space -> the one capture on the way
        self._targets = {}  # (profile, session) -> the Space it last showed

    def typing(self):
        try:
            return bool(self.typing_reader())
        except Exception:
            return True

    def _paused(self, public):
        """No frame and no pointer while a saved sign-in may be on screen, and no frame kept for later."""
        self._cache = {}
        return {"state": "paused", **{k: public[k] for k in ("kind", "computer_name") if k in public},
                "message": PAUSED}

    def is_private(self, profile):
        """Read the Private list on every request; an unreadable list refuses the preview."""
        try:
            return profile.lower() in self.private_reader()
        except Exception:
            return True

    def _note_target(self, chat, sandbox):
        """A chat that moved to another computer lets the old one's child go, unless another chat still shows it."""
        previous = self._targets.pop(chat, None)
        self._targets[chat] = sandbox
        while len(self._targets) > 64:
            del self._targets[next(iter(self._targets))]
        if self.pool and previous and previous != sandbox and previous not in self._targets.values():
            self.pool.release(previous)

    async def _shared(self, sandbox):
        """At most one capture per Space at a time; everyone asking meanwhile gets the same picture."""
        flight = self._flights.get(sandbox)
        if flight is None:
            async def take():
                data = await self.capture(sandbox)
                return data, self.clock()
            flight = asyncio.ensure_future(take())
            self._flights[sandbox] = flight
            def landed(done):
                if self._flights.get(sandbox) is done:
                    del self._flights[sandbox]
            flight.add_done_callback(landed)
        # A caller that gives up never cancels the picture others are waiting for.
        return await asyncio.shield(flight)

    async def _frame(self, profile, session_id, target, fresh):
        # Private bots are checked again before any capture and before any picture is handed out.
        if self.is_private(profile):
            raise Refused()
        # No capture and no kept frame while a saved sign-in may be on screen.
        if self.typing():
            raise Paused()
        now = self.clock()
        self._cache = {k: v for k, v in self._cache.items() if now - v["captured_at"] < 1.5}
        key = (profile, session_id, target["sandbox"], target["target_source"])
        if not fresh and key in self._cache:
            return self._cache[key]
        data, captured_at = await self._shared(target["sandbox"])
        if self.is_private(profile):
            raise Refused()
        # A sign-in that began during the capture may be in this frame: it is dropped, never kept or shown.
        if self.typing():
            raise Paused()
        # Who holds the computer is read fresh for every answer, never cached with the frame.
        frame = {"state": "live", **{k: target[k] for k in ("kind", "computer_name", "target_source")},
                 "image_data_url": data, "captured_at": captured_at}
        self._cache[key] = frame
        def expire():
            if self._cache.get(key) is frame:
                self._cache.pop(key, None)
        asyncio.get_running_loop().call_later(1.5, expire)
        return frame

    async def close(self):
        if self.pool:
            await self.pool.close()

    async def preview(self, profile, session_id, fresh=False):
        """fresh skips the 1.5 s cache but still shares a capture already on the way."""
        if (not isinstance(profile, str) or not IDENTIFIER.fullmatch(profile)
                or not isinstance(session_id, str) or not IDENTIFIER.fullmatch(session_id)
                or self.is_private(profile)):
            return dict(REFUSED)
        public, shown = {}, UNKNOWN  # the Space this chat shows, once that is known
        try:
            messages = await self.reader(profile, session_id)
            target = resolve_target(messages)
            owned = self.owned_reader(profile)
            owned_target = ({"kind": "space", "computer_name": owned.split(":", 1)[1],
                             "sandbox": owned, "target_source": "owned"}
                            if isinstance(owned, str) and SPACE_TARGET.fullmatch(owned) else None)
            if pending_mac_call(messages):
                shown = None
                if self.typing():
                    return self._paused({"kind": "mac", "computer_name": "This Mac"})
                return {"state": "unavailable", "kind": "mac", "computer_name": "This Mac",
                        "target_source": "session", "message": "Live preview is not available for this Mac yet."}
            if target is None or target["kind"] == "mac":
                target = owned_target or target
            shown = target and target["sandbox"]
            if target is None:
                return {"state": "idle", "message": "No computer has been used in this chat yet."}
            target.setdefault("target_source", "session")
            public = {key: target[key] for key in ("kind", "computer_name", "target_source")}
            control = self.control_reader(profile)
            if control in ("helper", "you", "someone"):
                public["control"] = control
            if not target["sandbox"]:
                if self.typing():
                    return self._paused(public)
                return {"state": "unavailable", **public, "message": "Live preview is not available for this computer yet."}
            try:
                frame = await self._frame(profile, session_id, target, fresh)
            except SpaceMissing:
                if not owned_target or target["sandbox"] == owned_target["sandbox"]:
                    raise
                target = owned_target
                public = {**{key: target[key] for key in ("kind", "computer_name", "target_source")},
                          **({"control": public["control"]} if "control" in public else {})}
                shown = target["sandbox"]
                frame = await self._frame(profile, session_id, target, fresh)
            result = {**frame, **public}
            if target.get("pointer"):
                result["pointer"] = dict(target["pointer"])
            return result
        except Paused:
            return self._paused(public)
        except Refused:
            return dict(REFUSED)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Never expose subprocess stderr, daemon addresses, session text, or remote errors.
            return {"state": "unavailable", **public, "message": "The computer preview is unavailable right now."}
        finally:
            # Recorded once, for the computer actually shown, so a fallback to the owned computer keeps its child.
            if shown is not UNKNOWN:
                self._note_target((profile, session_id), shown)
