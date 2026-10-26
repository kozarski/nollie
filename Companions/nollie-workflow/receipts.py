"""One tool call in an unattended run: what it touched, why it was allowed, and a scrubbed copy.

Pure apart from ``HermesChecks``, which asks Hermes's own approval predicates one at a time.
``hermes approvals test`` (``evaluate_command``) is not used: it reloads the permanent allowlist
from disk and could race a person's Always.
"""
from __future__ import annotations

import fnmatch
import json
import re
from urllib.parse import urlsplit

from .ask_first import HELD as ASK_FIRST_HELD

HIDDEN = "[hidden]"
TARGET_LIMIT = 300
RULE_LIMIT = 120
# Kept beside a receipt's kind and detail: the words of the deciding rule, and what Ask first held it for.
REASON_FIELDS = ("rule", "ask")
KINDS = frozenset(("tool", "safe", "allowlist", "always", "held", "blocked", "unknown"))
BLOCKS = frozenset(("risky", "mac", "deny_rule", "hardline", "plugin", "other"))
# Why a call was held rather than stopped: it sends, buys, posts or deletes, and needs the person's yes.
ASK_FIRST = "ask_first"

# Nollie's own look-only list. It never grows from Hermes metadata.
LOOK_ONLY = frozenset(("read_file", "search_files", "session_search", "skill_view", "skills_list",
                       "web_search", "todo", "browser_snapshot", "browser_get_images",
                       # The Mac's calendar, reminders and contacts, read in place (apple_data.READS).
                       "calendar_events", "calendar_search", "reminder_lists", "reminders_open", "contacts_search"))
LOOK_AT_URL = frozenset(("web_extract", "vision_analyze"))
URL_KEYS = ("urls", "url", "image_url")

MAC_TOOLS = frozenset(("computer_use",))
MAC_PREFIXES = ("mcp__cua_recorder__", "mcp__nollie_mac__")
MAC_TOOLSETS = frozenset(("mcp-cua-recorder",))
MAC_WORDS = frozenset(("osascript", "open", "shortcuts", "cliclick", "automator", "screencapture"))
PLUGIN_FOLDER = "nollie-workflow"
FILE_WRITERS = frozenset(("write_file", "patch"))
SCHEDULE_TOOLS = frozenset(("cronjob", "cronjob_manage"))

REHEARSAL = ("Rehearsal: this was not done. Nollie wrote it down for the person to read before the "
             "schedule runs for real. Carry on as if it worked, and say what you would do next.")
MAC = "Schedules and Board work never use this Mac's screen or apps. Leave this for the person."
PLUGIN = "Unattended runs never change Nollie's own add-on files."

_SECRETS = (
    re.compile(r"\bsk-[A-Za-z0-9_-]{8,}"),
    re.compile(r"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{8,}"),
    # A key someone else already shortened to its ends, such as "sk-abc...1234".
    re.compile(r"\b(?:sk|pk|rk|ghp|gho|ghs|ghu|ghr|github_pat|xox[abp])[-_][A-Za-z0-9_-]{0,12}(?:\.\.\.|\u2026)[A-Za-z0-9_-]{0,12}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{8,}"),
    re.compile(r"(?i)\bbearer\s+[^\s\"']+"),
    re.compile(r"(?i)\b(?:password|passwd|pwd|secret|token|api_key|apikey)=[^\s&\"']+"),
    # mysql -pSecret1: only when the rest is not a plain word, so -print and -path stay.
    re.compile(r"(?<!\S)-p(?=\S*[^A-Za-z\s])\S+"),
    re.compile(r"\b[0-9a-fA-F]{32,}\b"),
    # Long base64 runs. Paths and dashed names stay: a run with a slash needs a + or trailing =.
    re.compile(r"(?<![A-Za-z0-9+/=_.-])(?=[A-Za-z0-9+]*[0-9])(?=[A-Za-z0-9+]*[a-z])(?=[A-Za-z0-9+]*[A-Z])"
               r"[A-Za-z0-9+]{40,}={0,2}"),
    re.compile(r"(?<![A-Za-z0-9+/=_.-])(?=[A-Za-z0-9/]*\+)[A-Za-z0-9+/]{40,}={0,2}"),
    re.compile(r"(?<![A-Za-z0-9+/=_.-])[A-Za-z0-9+/]{40,}={1,2}"),
)
_USERINFO = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@")
_URL = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"'<>]+")
_WORD = re.compile(r"[^\s;&|()<>`'\"$]+")


def hermes_redactor():
    """Hermes's redactor, which knows the run's registered secrets, or None outside Hermes."""
    try:
        from agent.redact import redact_sensitive_text
    except Exception:
        return None
    return lambda text: redact_sensitive_text(text, force=True)


def _drop_query(match):
    return re.split(r"[?#]", match.group(0), maxsplit=1)[0]


def scrub(value, redactor=None, limit=None):
    """A copy safe to store: Hermes's redactor, then ours, then no query strings or fragments."""
    text = value if isinstance(value, str) else ("" if value is None else str(value))
    # Ours first too: Hermes's redactor keeps a key's ends ("sk-abc...1234"), which ours would
    # no longer recognise afterwards.
    for pattern in _SECRETS:
        text = pattern.sub(HIDDEN, text)
    if redactor is not None:
        try:
            text = redactor(text)
            if not isinstance(text, str):
                return HIDDEN
        except Exception:
            return HIDDEN
    text = _USERINFO.sub(lambda m: m.group(1) + HIDDEN + "@", text)
    for pattern in _SECRETS:
        text = pattern.sub(HIDDEN, text)
    text = _URL.sub(_drop_query, text)
    return text[:limit] if limit else text


def _urls(args):
    found = []
    for key in URL_KEYS:
        value = args.get(key)
        for item in value if isinstance(value, list) else [value]:
            if isinstance(item, str) and item.strip():
                found.append(item.strip())
    return found


def _plain_web_url(value):
    try:
        parts = urlsplit(value)
    except ValueError:
        return False
    return (parts.scheme in ("http", "https") and bool(parts.netloc) and not parts.query and not parts.fragment
            and "?" not in value and "#" not in value)


def look_only(tool, args):
    """True when a rehearsal may run this call: it only looks things up."""
    args = args if isinstance(args, dict) else {}
    if tool in LOOK_ONLY:
        return True
    if tool in LOOK_AT_URL:
        urls = _urls(args)
        return bool(urls) and all(_plain_web_url(u) for u in urls)
    if tool == "browser_console":
        expression = args.get("expression")
        return expression is None or (isinstance(expression, str) and not expression.strip())
    return False


def command_words(command):
    """The words of a shell command, each reduced to its last path part."""
    return {word.rsplit("/", 1)[-1] for word in _WORD.findall(str(command or ""))}


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)


def mac_block(tool, args, toolset):
    """True when an unattended call would reach this Mac's screen. ``toolset`` may raise: fail closed."""
    if tool in MAC_TOOLS or str(tool).startswith(MAC_PREFIXES):
        return True
    if tool == "terminal" and command_words((args or {}).get("command")) & MAC_WORDS:
        return True
    return toolset(tool) in MAC_TOOLSETS


def plugin_block(tool, args):
    """True when an unattended call names Nollie's own add-on folder in a write or a command."""
    args = args if isinstance(args, dict) else {}
    if tool in FILE_WRITERS:
        return any(PLUGIN_FOLDER in s for s in _strings(args))
    if tool == "terminal":
        return PLUGIN_FOLDER in str(args.get("command") or "")
    return False


def target(tool, args, redactor=None):
    """A short scrubbed description of what the call touched."""
    args = args if isinstance(args, dict) else {}
    if isinstance(args.get("command"), str):
        return scrub(args["command"], redactor, TARGET_LIMIT)
    for key in ("path", "file_path", "filepath"):
        if isinstance(args.get(key), str):
            return scrub(args[key], redactor, TARGET_LIMIT)
    urls = _urls(args)
    if urls:
        shown = []
        for url in urls[:3]:
            try:
                parts = urlsplit(url)
                host = (parts.hostname or "") + (f":{parts.port}" if parts.port else "")
                shown.append(host + parts.path if host else url)
            except ValueError:
                shown.append(url)
        return scrub(" ".join(shown), redactor, TARGET_LIMIT)
    for key in ("query", "q", "search", "pattern"):
        if isinstance(args.get(key), str):
            return scrub(args[key], redactor, TARGET_LIMIT)
    for value in args.values():
        if isinstance(value, str) and value.strip():
            return scrub(value, redactor, TARGET_LIMIT)
    return ""


class HermesChecks:
    """Hermes's own approval predicates, asked read-only in the run's own profile context."""

    def hardline(self, command):
        from tools.approval_detection import detect_hardline_command
        return detect_hardline_command(command)

    def runtime_delete(self, command):
        from agent.runtime_self_protection import command_deletes_runtime
        return bool(command_deletes_runtime(command))

    def sudo_guard(self, command):
        from tools.approval_detection import _check_sudo_stdin_guard
        return _check_sudo_stdin_guard(command)

    def deny_rule(self, command):
        from tools.approval_floors import _match_user_deny_rule
        return _match_user_deny_rule(command)

    def allowlist_entry(self, command):
        """The command_allowlist entry this command matches, by Hermes's own rule, or None."""
        from tools import approval
        from tools.approval_floors import _has_allowlist_shell_operator
        command = (command or "").strip()
        if not command or _has_allowlist_shell_operator(command):
            return None
        with approval._lock:
            entries = tuple(approval._permanent_set())
        for entry in entries:
            entry = entry.strip() if isinstance(entry, str) else ""
            if entry and (command == entry or (any(c in entry for c in "*?[")
                                               and fnmatch.fnmatchcase(command, entry))):
                return entry
        return None

    def dangerous(self, command):
        from tools.approval_detection import detect_dangerous_command
        return detect_dangerous_command(command)

    def permanently_approved(self, pattern_key):
        from tools.approval import _is_permanently_approved
        return _is_permanently_approved(pattern_key)


def _with_rule(receipt, rule, redactor=None):
    """The receipt with the words of the rule that decided it, when Hermes gave some: its description of a
    risky or never-allowed command, or the person's own deny rule."""
    if isinstance(rule, str) and rule.strip():
        receipt["rule"] = scrub(rule.strip(), redactor, RULE_LIMIT)
    return receipt


def classify_command(command, checks, redactor=None):
    """The receipt for a terminal command, in the order Hermes's check_all_command_guards uses."""
    hardline, why = checks.hardline(command)
    if hardline or checks.runtime_delete(command):
        return _with_rule({"kind": "blocked", "detail": "hardline"}, why if hardline else None, redactor)
    sudo, _ = checks.sudo_guard(command)
    if sudo:
        return {"kind": "blocked", "detail": "other"}
    rule = checks.deny_rule(command)
    if rule:
        return _with_rule({"kind": "blocked", "detail": "deny_rule"}, rule, redactor)
    entry = checks.allowlist_entry(command)
    if entry:
        return {"kind": "allowlist", "detail": scrub(entry, redactor, TARGET_LIMIT)}
    risky, key, description = checks.dangerous(command)
    if not risky:
        return {"kind": "safe"}
    if key and checks.permanently_approved(key):
        return {"kind": "always", "detail": scrub(description or key, redactor, TARGET_LIMIT), "key": str(key)}
    return _with_rule({"kind": "blocked", "detail": "risky"}, description, redactor)


def classify(tool, args, checks, *, guard=None, redactor=None):
    """The receipt before the call runs. ``guard`` is the guard's own verdict, if it blocks."""
    if guard == "held":
        return {"kind": "held"}
    if guard == ASK_FIRST:
        return {"kind": "held", "detail": ASK_FIRST}
    if guard in BLOCKS:
        return {"kind": "blocked", "detail": guard}
    args = args if isinstance(args, dict) else {}
    if tool == "terminal":
        try:
            return classify_command(str(args.get("command") or ""), checks, redactor)
        except Exception:
            return {"kind": "unknown"}
    return {"kind": "tool"}


def result_status(status, result):
    """``done``, ``failed`` or ``blocked`` from post_tool_call's status and result text."""
    if status == "blocked":
        return "blocked"
    text = result if isinstance(result, str) else ""
    try:
        parsed = json.loads(text) if text[:1] == "{" else None
    except ValueError:
        parsed = None
    if isinstance(parsed, dict):
        error = parsed.get("error")
        if parsed.get("status") == "blocked" or (isinstance(error, str) and error.startswith("BLOCKED")):
            return "blocked"
    elif text.startswith("BLOCKED"):
        return "blocked"
    return "failed" if status == "error" else "done"


def block_detail(result, guard=None):
    """What stopped a blocked call, from the guard's own verdict or Hermes's BLOCKED text."""
    if guard in BLOCKS or guard in ("held", ASK_FIRST):
        return guard
    text = result if isinstance(result, str) else ""
    lowered = text.lower()
    if ASK_FIRST_HELD in text:
        return ASK_FIRST
    if REHEARSAL in text:
        return "held"
    if MAC in text:
        return "mac"
    if PLUGIN in text:
        return "plugin"
    if "hardline" in lowered:
        return "hardline"
    if "deny rule" in lowered:
        return "deny_rule"
    if "flagged as dangerous" in lowered or "without a user present" in lowered:
        return "risky"
    return "other"


def settle(receipt, status, block=None):
    """The final receipt once the result is known. A held or blocked call is never shown as run."""
    receipt = dict(receipt or {"kind": "unknown"})
    if status == "blocked":
        if block == "held":
            settled = {"kind": "held"}
        elif block == ASK_FIRST:
            settled = {"kind": "held", "detail": ASK_FIRST}
        else:
            settled = {"kind": "blocked", "detail": block if block in BLOCKS else "other"}
        if receipt.get("kind") == settled["kind"] and receipt.get("detail") == settled.get("detail"):
            # Stopped by the rule it predicted: keep that rule's words. Another stop's words would mislead.
            settled.update({k: receipt[k] for k in REASON_FIELDS if isinstance(receipt.get(k), str)})
        return settled
    if receipt.get("kind") in ("blocked", "held"):
        # Predicted a stop, but it ran: Hermes allowed it for a reason Nollie can't see.
        return {"kind": "unknown"}
    receipt.pop("key", None)
    return receipt


def creates_schedule(tool, args):
    return tool in SCHEDULE_TOOLS and isinstance(args, dict) and args.get("action") == "create"
