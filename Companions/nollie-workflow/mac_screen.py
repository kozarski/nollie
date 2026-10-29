"""This Mac's screen stays on this Mac: Hermes's own ``computer_use``, and taking a picture of the screen from a bot's
terminal or code, are refused for every bot that is not private.

``computer_use`` hands whole screenshots of the Mac, and the screen's words, to the bot's own model (often an
online one), in any app. Nollie's way (the nollie-mac add-on: ``mac_start``, then ``mac_do``) works only in the
apps the person picked, a model on the Mac does the clicking, and only a short sentence comes back. A fixed rule,
never the model's judgement: the call is refused before it runs, and a result that got through anyway is
replaced, with Hermes's cached copy of its picture removed. Bots' own computers (``mcp__cua__*``) are theirs, not
this Mac, and are left alone.
"""

import os
from pathlib import Path
import re

TOOLS = frozenset({"computer_use"})
SHELL_TOOLS = frozenset({"terminal", "process", "process_manage"})
CODE_TOOLS = frozenset({"execute_code"})
WRAPPERS = frozenset({"tool_call", "connectors__execute", "multi_tool_use.parallel", "parallel"})
SCRIPT_LIMIT = 256 * 1024
# Programs, system calls and libraries that take a picture of the screen or record it. Matched on whole words in
# the command, the code, and any script the command runs, so `screencapture`, Quartz's CGWindowListCreateImage
# through Python or osascript, ScreenCaptureKit from Swift, PIL's ImageGrab and ffmpeg's screen input all count.
CAPTURE = re.compile(
    r"(?<![\w-])(?:screencapture|screenshot\.app|peekaboo|imagesnap)(?![\w-])"
    r"|\b(?:CGWindowListCreateImage\w*|CGDisplayCreateImage\w*|CGDisplayStream\w*|CGRegionCreateImage\w*"
    r"|SCScreenshotManager|SCStreamConfiguration|SCContentFilter|SCShareableContent|ScreenCaptureKit"
    r"|captureImage(?:InRect|WithFilter)\w*|AVCaptureScreenInput|CGSHWCaptureWindowList\w*|CGSCaptureWindowsContentsToRect\w*)\b"
    r"|\bImageGrab\b|\bpyautogui\s*\.\s*screenshot\b|\bpyscreenshot\b|\bimport\s+mss\b|\bfrom\s+mss\b|\bmss\s*\.\s*mss\b"
    r"|\bscreenshot-desktop\b|\btake\s+screenshot\b"
    r"|-f\s+avfoundation\b|\bcapture\s+screen\b",
    re.IGNORECASE)
SCRIPTS = re.compile(r"(?:^|\s)([^\s'\"]+\.(?:py|sh|bash|zsh|swift|js|mjs|ts|rb|pl|scpt|applescript|command))(?=\s|$|;|&|\|)")
MESSAGE = ("Not done: this Mac's screen stays on this Mac. To use apps here, ask with mac_start and then mac_do: "
           "a model on the Mac does the clicking, in the apps the person picked.")
REPLACED = "This Mac's screen stays on this Mac, so what that call saw was thrown away."
CAPTURE_MESSAGE = ("Not done: bots don't take pictures of this Mac's screen. To use apps here, ask with mac_start and "
                   "then mac_do: a model on the Mac does the looking, in the apps the person picked.")


def _read_script(path, cwd):
    try:
        candidate = Path(os.path.expanduser(path))
        if not candidate.is_absolute():
            candidate = Path(cwd or os.getcwd()) / candidate
        if not candidate.is_file() or candidate.stat().st_size > SCRIPT_LIMIT:
            return ""
        return candidate.read_text(errors="replace")
    except (OSError, ValueError):
        return ""


def _texts(tool, args, depth=0):
    """Every piece of command or code a call would run: the command, typed input, code, the scripts the command
    names, and the same for each call inside a wrapper."""
    if depth > 3 or not isinstance(args, dict):
        return
    if tool in SHELL_TOOLS:
        cwd = args.get("workdir") or args.get("cwd")
        for key in ("command", "cmd", "script", "data", "input", "text"):
            value = args.get(key)
            if isinstance(value, str) and value.strip():
                yield value
                for script in SCRIPTS.findall(value)[:8]:
                    yield _read_script(script, cwd)
    elif tool in CODE_TOOLS:
        for key in ("code", "source"):
            if isinstance(args.get(key), str):
                yield args[key]
    elif tool in WRAPPERS or tool.endswith("__execute"):
        for key in ("calls", "tool_uses", "tools", "actions"):
            for call in args.get(key) or []:
                if isinstance(call, dict):
                    name = str(call.get("tool") or call.get("tool_name") or call.get("name") or call.get("recipient_name") or "")
                    inner = next((call[k] for k in ("arguments", "args", "parameters", "input", "params") if isinstance(call.get(k), dict)), {})
                    yield from _texts(name.rsplit(".", 1)[-1], inner, depth + 1)
        name = str(args.get("tool") or args.get("tool_name") or args.get("name") or "")
        inner = next((args[k] for k in ("arguments", "args", "parameters", "input", "params") if isinstance(args.get(k), dict)), None)
        if name and inner is not None:
            yield from _texts(name, inner, depth + 1)


def takes_a_picture(tool, args):
    """True when a terminal, code or wrapped call would take a picture of the screen, or record it."""
    return any(text and CAPTURE.search(text) for text in _texts(str(tool or ""), args if isinstance(args, dict) else {}))


def refuse(tool_name=None, args=None, **_):
    """``pre_tool_call``: refused, never asked. A call that can't be read is let through to Ask first."""
    if str(tool_name or "") in TOOLS:
        return {"action": "block", "message": MESSAGE}
    try:
        if takes_a_picture(tool_name, args):
            return {"action": "block", "message": CAPTURE_MESSAGE}
    except Exception:
        return {"action": "block", "message": CAPTURE_MESSAGE}
    return None


def scrub(tool_name=None, args=None, result=None, **_):
    """``transform_tool_result``: nothing a ``computer_use`` call saw reaches the model."""
    if str(tool_name or "") not in TOOLS:
        return None
    try:
        from .sign_ins import _remove_cached_pictures
        _remove_cached_pictures(result)
    except Exception:
        pass
    return REPLACED


def register(ctx):
    ctx.register_hook("pre_tool_call", refuse)
    ctx.register_hook("transform_tool_result", scrub)
