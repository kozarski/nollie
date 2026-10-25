"""What is on a computer's screen where a click lands, for Ask first's "You're about to press" check.

Three computers, three sources, all read by rules, never by a model:

- a helper's own Cua computer: a fresh screenshot through Cua's command-line tool, read with the Mac's
  own text recognition (Vision, through JavaScript for Automation). Click coordinates are in the
  screenshot's pixels, so the text under the click is the text in that spot;
- this Mac through Hermes's ``computer_use``: the element labels from the bot's own latest capture,
  remembered from its result (Hermes keeps none it would share);
- Hermes's own browser: the accessible names from the bot's latest page snapshot, remembered the same way.

When nothing can be read, the answer is UNREADABLE and Ask first asks. Nothing here keeps a picture: the
screenshot lives in memory for one reading and is dropped.
"""
from __future__ import annotations

import ast
import base64
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import tempfile
import threading

from .ask_first import UNREADABLE

CUA_APP = "Cua Spaces.app"
CUA_TOOL = CUA_APP + "/Contents/MacOS/cua"
SPACE_TARGET = re.compile(r"(local|cloud):[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
BARE_TARGET = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
CAPTURE_SECONDS = 8.0
READ_SECONDS = 8.0
MAX_IMAGE = 8 * 1024 * 1024
# Text this close to a click counts as under it: a button's label sits inside its padding.
REACH = 12
MEMORY = 64
OCR_SCRIPT = Path(__file__).with_name("screen_text.js")


# Remembered captures -------------------------------------------------------------------------

_SUMMARY = re.compile(r"^\s{2}#(\d+) (.+?) ('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\") @ "
                      r"(?:bounds-unknown \(click by element index\)|[\(\[](-?\d+), (-?\d+), (-?\d+), (-?\d+)[\)\]])"
                      r"(?: \[(.*)\])?$")
_REF = re.compile(r'^\s*-\s+([\w-]+)(?:\s+"((?:[^"\\]|\\.)*)")?[^\[\n]*\[[^\]]*\bref=(e\d+)\b[^\]]*\](?::\s*(.*))?$',
                  re.M)


def _literal(text):
    try:
        value = ast.literal_eval(text)
        return value if isinstance(value, str) else None
    except (ValueError, SyntaxError):
        return None


def capture_elements(result):
    """Element labels and bounds from a ``computer_use`` capture result: {index: {role, label, bounds}}."""
    elements, scale, spill = {}, None, None
    if isinstance(result, dict) and result.get("_multimodal"):
        meta = result.get("meta") or {}
        scale, spill = meta.get("bounds_scale"), meta.get("elements_file")
        for line in str(result.get("text_summary") or "").splitlines():
            match = _SUMMARY.match(line)
            if match:
                bounds = None if match.group(4) is None else [int(match.group(i)) for i in (4, 5, 6, 7)]
                elements[int(match.group(1))] = {"role": match.group(2), "label": _literal(match.group(3)),
                                                 "bounds": bounds}
    else:
        text = result if isinstance(result, str) else None
        try:
            document = json.loads(text) if text else None
        except ValueError:
            document = None
        if not isinstance(document, dict) or not isinstance(document.get("elements"), list):
            # A capture_after action puts its own JSON first, then the capture.
            if text and "\n\n" in text:
                return capture_elements(text.split("\n\n", 1)[1])
            return None
        scale, spill = document.get("bounds_scale"), document.get("elements_file")
        for item in document["elements"]:
            if isinstance(item, dict) and isinstance(item.get("index"), int):
                elements[item["index"]] = {"role": item.get("role"), "label": item.get("label"),
                                           "bounds": item.get("bounds")}
    if isinstance(spill, str) and spill:
        try:
            path = Path(spill)
            if path.is_file() and not path.is_symlink() and path.stat().st_size < 4 * 1024 * 1024:
                full = json.loads(path.read_text())
                elements = {item["index"]: {"role": item.get("role"), "label": item.get("label"),
                                            "bounds": item.get("bounds")}
                            for item in full.get("elements", []) if isinstance(item, dict)
                            and isinstance(item.get("index"), int)}
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return {"elements": elements, "scale": scale if isinstance(scale, (int, float)) else None}


def snapshot_refs(result):
    """Accessible names from a browser snapshot result: {"e12": "Buy now"} and the page's words."""
    try:
        document = json.loads(result) if isinstance(result, str) else result
    except ValueError:
        return None
    snapshot = document.get("snapshot") if isinstance(document, dict) else None
    if not isinstance(snapshot, str) or not snapshot:
        return None
    refs = {}
    for match in _REF.finditer(snapshot):
        name = match.group(2) or match.group(4) or ""
        refs[match.group(3)] = name.replace('\\"', '"')
    return {"refs": refs, "text": snapshot}


class Memory:
    """The latest capture per chat and the latest page per task, for the click that follows."""

    def __init__(self, limit=MEMORY):
        self.lock = threading.Lock()
        self.captures = {}
        self.pages = {}
        self.limit = limit

    def _put(self, store, key, value):
        with self.lock:
            store.pop(key, None)
            store[key] = value
            while len(store) > self.limit:
                store.pop(next(iter(store)))

    def post_tool_call(self, tool_name=None, args=None, result=None, task_id=None, session_id=None, **_):
        try:
            args = args if isinstance(args, dict) else {}
            if tool_name == "computer_use":
                action = str(args.get("action") or "").lower()
                if action == "capture" or args.get("capture_after"):
                    found = capture_elements(result)
                    if found is not None:
                        self._put(self.captures, session_id or "", found)
                        return None
                if action not in ("list_apps", "list_windows", "wait"):
                    # The screen may have changed since the capture: the next click is read afresh or asks.
                    with self.lock:
                        self.captures.pop(session_id or "", None)
            elif tool_name in ("browser_snapshot", "browser_navigate"):
                found = snapshot_refs(result)
                if found is not None:
                    self._put(self.pages, task_id or "default", found)
                elif tool_name == "browser_navigate":
                    with self.lock:
                        self.pages.pop(task_id or "default", None)
            elif tool_name in ("browser_back", "browser_click", "browser_press", "browser_type", "browser_console",
                               "browser_exec", "browser_cdp", "browser_dialog"):
                # The page may have changed: refs from the last snapshot can't be trusted for the next step.
                with self.lock:
                    self.pages.pop(task_id or "default", None)
        except Exception:
            pass
        return None

    def element(self, session_id, args):
        with self.lock:
            capture = self.captures.get(session_id or "")
        if not capture:
            return None
        element = args.get("element")
        if element is not None:
            try:
                return capture["elements"].get(int(element))
            except (TypeError, ValueError):
                return None
        coordinate = args.get("coordinate")
        if isinstance(coordinate, (list, tuple)) and len(coordinate) == 2:
            try:
                scale = capture["scale"] or 1.0
                x, y = float(coordinate[0]) * scale, float(coordinate[1]) * scale
            except (TypeError, ValueError):
                return None
            hits = [e for e in capture["elements"].values() if isinstance(e.get("bounds"), list)
                    and len(e["bounds"]) == 4 and e["bounds"][0] <= x < e["bounds"][0] + e["bounds"][2]
                    and e["bounds"][1] <= y < e["bounds"][1] + e["bounds"][3]]
            return min(hits, key=lambda e: e["bounds"][2] * e["bounds"][3]) if hits else None
        return None

    def capture_text(self, session_id):
        with self.lock:
            capture = self.captures.get(session_id or "")
        if not capture:
            return None
        return " ".join(str(e.get("label") or "") for e in capture["elements"].values())

    def page(self, task_id):
        with self.lock:
            return self.pages.get(task_id or "default")


# A Cua computer's screen ---------------------------------------------------------------------

def account_home():
    """The person's real home: Nollie's runtime gives Hermes a private HOME, but Cua lives in theirs."""
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except (KeyError, OSError):
        return Path.home()


def find_cua(home, environ=None):
    """Cua's CLI by full path, in the order Nollie's own computer add-on looks for it."""
    environ = os.environ if environ is None else environ
    named = environ.get("NOLLIE_CUA_CLI")
    candidates = []
    if named and os.path.isabs(named) and named.endswith("/" + CUA_TOOL) and ".." not in Path(named).parts:
        candidates.append(Path(named))
    candidates += [Path("/Applications") / CUA_TOOL, Path(home) / "Applications" / CUA_TOOL,
                   Path(home) / "Library/Application Support/Nollie/Cua" / CUA_TOOL]
    which = shutil.which("cua")
    if which:
        candidates.append(Path(which))
    candidates += [Path(home) / ".local/bin/cua", Path("/opt/homebrew/bin/cua"), Path("/usr/local/bin/cua")]
    for candidate in candidates:
        if os.access(candidate, os.X_OK) and not os.path.isdir(candidate):
            return str(candidate)
    return None


def _rpc(process, request_id, method, params):
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n")
    process.stdin.flush()
    total = 0
    for _ in range(32):
        line = process.stdout.readline()
        if not line:
            break
        total += len(line)
        if total > MAX_IMAGE * 2:
            break
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict) and message.get("id") == request_id:
            return message.get("result")
    return None


def capture_space(sandbox, environ=None, run=subprocess.Popen):
    """One PNG of a Cua computer, or None. Only screenshot permission; nothing is written to disk."""
    home = account_home()
    cua = find_cua(home, environ)
    socket = home / ".cua" / "cua.sock"
    try:
        if not cua or not stat.S_ISSOCK(socket.lstat().st_mode):
            return None
    except OSError:
        return None
    env = {**(os.environ if environ is None else environ), "HOME": str(home), "CUA_TELEMETRY": "0",
           "NO_COLOR": "1"}
    process = run([cua, "--daemon", str(socket), "mcp", "--permissions", "computer:screenshot"],
                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    timer = threading.Timer(CAPTURE_SECONDS, process.kill)
    timer.start()
    try:
        _rpc(process, 1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                        "clientInfo": {"name": "nollie-ask-first", "version": "0.1.0"}})
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        process.stdin.flush()
        arguments = {"sandbox": sandbox} if sandbox else {}
        result = _rpc(process, 2, "tools/call", {"name": "computer_screenshot", "arguments": arguments})
        if not isinstance(result, dict) or result.get("isError"):
            return None
        for part in result.get("content") or []:
            if isinstance(part, dict) and part.get("type") == "image" and isinstance(part.get("data"), str):
                data = base64.b64decode(part["data"], validate=False)
                return data if len(data) <= MAX_IMAGE else None
        return None
    except (OSError, ValueError):
        return None
    finally:
        timer.cancel()
        try:
            process.kill()
            process.wait(timeout=2)
        except Exception:
            pass


def read_text(image, run=subprocess.run):
    """The words in a picture with their boxes, by the Mac's own text recognition. None if it failed."""
    if not image or not OCR_SCRIPT.is_file():
        return None
    with tempfile.TemporaryDirectory(prefix="nollie-ocr-") as folder:
        path = Path(folder) / "screen.png"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(image)
        try:
            done = run(["/usr/bin/osascript", "-l", "JavaScript", str(OCR_SCRIPT), str(path)],
                       capture_output=True, text=True, timeout=READ_SECONDS)
        except (OSError, subprocess.SubprocessError):
            return None
    try:
        found = json.loads(done.stdout)
    except ValueError:
        return None
    found = found.get("items") if isinstance(found, dict) else None
    if not isinstance(found, list):
        return None
    words = [w for w in found if isinstance(w, dict) and isinstance(w.get("text"), str)
             and all(isinstance(w.get(k), (int, float)) for k in ("x", "y", "w", "h"))]
    # A screen with no words at all means the reading failed (Vision reports success with nothing when
    # the GPU is unwell), not that the screen is blank.
    return words or None


def text_at(words, x, y, reach=REACH):
    """The words whose box holds the point, nearest first, joined as one label."""
    hits = [w for w in words if w["x"] - reach <= x <= w["x"] + w["w"] + reach
            and w["y"] - reach <= y <= w["y"] + w["h"] + reach]
    hits.sort(key=lambda w: abs(w["x"] + w["w"] / 2 - x) + abs(w["y"] + w["h"] / 2 - y))
    return hits[0]["text"] if hits else None


def owned_space(main_home, profile):
    """The bot's own Cua computer, from the record Nollie keeps, for calls that name none."""
    if not isinstance(profile, str) or not PROFILE_NAME.fullmatch(profile):
        return None
    path = Path(main_home) / "nollie-computer" / "owned-spaces.json"
    try:
        if path.is_symlink() or path.stat().st_size > 16384:
            return None
        document = json.loads(path.read_text())
        owners = document.get("profiles") if isinstance(document, dict) and document.get("version") == 1 else None
        target = owners.get(profile) if isinstance(owners, dict) else None
        return target if isinstance(target, str) and SPACE_TARGET.fullmatch(target) else None
    except (OSError, ValueError, UnicodeDecodeError):
        return None


class HermesScreen:
    """``label_at`` and ``text`` for Ask first, bound to one call's chat and task."""

    def __init__(self, memory=None, *, capture=capture_space, read=read_text, default_space=lambda: None):
        self.memory = memory or Memory()
        self.capture = capture
        self.read = read
        self.default_space = default_space

    def bind(self, task_id=None, session_id=None):
        return _Bound(self, task_id, session_id)

    # Without a binding (tests, or a caller that has none): nothing is remembered.
    def label_at(self, tool, args):
        return self.bind().label_at(tool, args)

    def text(self, tool, args):
        return self.bind().text(tool, args)


class _Bound:
    def __init__(self, screen, task_id, session_id):
        self.screen, self.task_id, self.session_id = screen, task_id, session_id
        self.words = None

    def _space_words(self, args):
        if self.words is None:
            sandbox = args.get("sandbox") or args.get("space")
            if not isinstance(sandbox, str) or not (SPACE_TARGET.fullmatch(sandbox) or BARE_TARGET.fullmatch(sandbox)):
                sandbox = self.screen.default_space()
            if not sandbox:
                self.words = UNREADABLE
            else:
                try:
                    image = self.screen.capture(sandbox)
                    found = self.screen.read(image) if image else None
                except Exception:
                    found = None
                self.words = found if found else UNREADABLE
        return self.words

    def label_at(self, tool, args):
        if tool == "computer_use":
            element = self.screen.memory.element(self.session_id, args)
            return UNREADABLE if element is None else (element.get("label") or "")
        if tool == "browser_click":
            page = self.screen.memory.page(self.task_id)
            ref = str(args.get("ref") or "").lstrip("@")
            if not page or ref not in page["refs"]:
                return UNREADABLE
            return page["refs"][ref]
        if tool.startswith("mcp__cua__"):
            x, y = args.get("x"), args.get("y")
            if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (x, y)):
                return UNREADABLE
            words = self._space_words(args)
            if words is UNREADABLE:
                return UNREADABLE
            return text_at(words, x, y) or ""
        return UNREADABLE

    def text(self, tool, args):
        if tool == "computer_use":
            seen = self.screen.memory.capture_text(self.session_id)
            return UNREADABLE if seen is None else seen
        if tool.startswith("browser_"):
            page = self.screen.memory.page(self.task_id)
            return UNREADABLE if not page else page["text"]
        if tool.startswith("mcp__cua__"):
            words = self._space_words(args)
            return UNREADABLE if words is UNREADABLE else " ".join(w["text"] for w in words)
        return UNREADABLE
