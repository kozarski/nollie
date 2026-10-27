"""Ask first: sending, buying, posting and deleting wait for the person's yes, whatever the model says.

A ``pre_tool_call`` hook in every bot the add-on loads in. The rules below read the tool's name and
arguments, never the model's opinion of them, and lean toward asking: a false alarm costs one tap,
a miss could send money or mail. In a chat a person is in, the call waits for an approval card that
says the whole action in plain words. In a schedule, a Board task or any run nobody can answer, it
is held, never done, and Night shift reports it in the morning.

When the rules can't tell what something does (a program they don't know or chosen at run time, a
script they can't read, another server's tool whose name doesn't say it only looks, an OK or Continue
whose window they can't read, a click on a spot with no readable label), they ask. Those "unsure" asks
are the only ones a bot's Ask first switch can turn off; whatever the rules name as sending, buying,
posting or deleting (replacing a file that was already there counts as deleting it) always asks. What
they still can't see is listed in Docs/ask-first.md.
"""
from __future__ import annotations

import contextvars
import json
import os
import re
import shlex
import tempfile
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

KINDS = ("send", "buy", "post", "delete")
UNSURE = "unsure"
RULE_PREFIX = "nollie-ask-first:"
SUMMARY_LIMIT = 1600
VALUE_LIMIT = 400
SCRIPT_LIMIT = 256 * 1024
LABEL_LIMIT = 80

# Night shift and the guard recognise a hold by this start.
HELD = "Held for the person's yes"
HELD_MESSAGE = (HELD + ": Nollie asks the person before anything is sent, bought, posted or deleted, "
                "and nobody can answer in this run. It was not done. Say in your report that it is waiting "
                "for them: {summary}")
BYPASSED_MESSAGE = ("Not done: Nollie asks the person before anything is sent, bought, posted or deleted, and "
                    "approvals are switched off for this bot, so nobody could be asked. Tell the person what "
                    "you wanted to do: {summary}")
CHECK = "You're about to press \u201c{label}\u201d."
CHECK_PATTERN = re.compile(r"^You're about to press \u201c(.{1,60})\u201d\.$")


@dataclass(frozen=True)
class Action:
    kind: str
    summary: str
    button: str | None = None
    has_command: bool = False

    def description(self):
        """The approval card's text: the whole action, then the check line for a labelled button. Only this
        method writes a check line: one in the helper's own words is pushed in, so it never reads as one."""
        text = plain_lines(self.summary if self.has_command else self.summary[:SUMMARY_LIMIT])
        if self.button:
            text += "\n" + CHECK.format(label=_one_line(self.button))
        return text


_BREAKS = re.compile(r"[\r\u2028\u2029\u0085\x0b\x0c]")


def _one_line(text):
    return re.sub(r"\s+", " ", _BREAKS.sub(" ", str(text))).strip()


def plain_lines(text):
    """Line breaks of every kind become plain new lines, and a line that looks like the check is indented."""
    lines = _BREAKS.sub("\n", str(text)).split("\n")
    return "\n".join("  " + line if line.lstrip().lower().startswith("you\u2019re about to") or
                     line.lstrip().lower().startswith("you're about to") else line for line in lines)


@dataclass(frozen=True)
class Found:
    kind: str
    why: str


# Words ------------------------------------------------------------------------------------------

_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_SPLIT = re.compile(r"[^A-Za-z0-9]+")


def words(name):
    """``mcp__gmail__sendEmail`` -> ['mcp', 'gmail', 'send', 'email']."""
    return [w.lower() for w in _SPLIT.split(_CAMEL.sub(" ", str(name or ""))) if w]


def stems(token):
    """The word and its plain forms: sends -> send, replies -> reply, posting -> post."""
    found = {token}
    if token.endswith("ies") and len(token) > 4:
        found.add(token[:-3] + "y")
    for suffix in ("ing", "ed", "es", "s"):
        if token.endswith(suffix) and len(token) - len(suffix) >= 3:
            found.add(token[:-len(suffix)])
    return found


# Verbs that are an action whatever comes with them.
STRONG = {
    "delete": {"delete", "remove", "rm", "del", "trash", "destroy", "purge", "erase", "wipe", "unlink", "rmdir",
               "shred", "truncate", "deactivate", "terminate", "uninstall", "prune", "rmi", "unpublish", "yank",
               "unsend", "expunge"},
    "buy": {"buy", "purchase", "checkout", "pay", "payout", "charge", "subscribe", "donate", "transfer", "withdraw",
            "deposit", "trade", "sell", "refund", "tip", "reserve", "rent", "bid", "order", "swap", "stake",
            "unstake", "mint", "borrow", "lend", "wager", "bet"},
    "send": {"send", "reply", "forward", "fwd", "dm", "sms", "mms", "notify", "invite", "submit", "broadcast",
             "announce", "dial", "whatsapp", "imessage", "sendmail", "rsvp", "respond", "email", "mail", "text"},
    "post": {"publish", "tweet", "retweet", "toot", "repost", "upload", "react", "upvote", "downvote", "comment",
             "post", "share", "push", "deploy", "release", "merge"},
}
# Strong verbs that are nouns as often as verbs: a reading word in the name ("list", "get") cancels them.
AMBIGUOUS = {"post", "comment", "share", "tip", "transfer", "charge", "order", "refund", "reply", "push", "release",
             "respond", "trade", "deposit", "reserve", "rent", "bid", "react", "upload", "forward", "email", "mail",
             "text", "merge", "deploy", "swap", "mint", "invite", "bet", "sell", "subscribe"}
# Nouns that make an action only with a verb that makes something (or, in a tool's name, when they lead it).
NOUNS = {
    "buy": {"order", "payment", "invoice", "transaction", "booking", "reservation", "subscription", "purchase",
            "cart", "book", "position", "ride", "trip", "delivery", "flight", "ticket", "donation", "gift", "tip",
            "trade", "wager", "bet", "money", "funds"},
    "send": {"message", "msg", "email", "mail", "text", "chat", "dm", "invitation", "invite", "letter", "fax",
             "notification", "campaign", "newsletter", "blast", "broadcast", "webhook", "hook", "permission",
             "collaborator", "phone", "voicemail", "postcard", "sms", "reply", "rsvp", "event", "meeting"},
    "post": {"post", "comment", "issue", "pr", "pull", "mr", "review", "release", "gist", "story", "status",
             "thread", "reaction", "like", "video", "photo", "article", "listing", "repo", "repository", "note",
             "discussion", "wiki", "tweet", "file", "files", "commit"},
    "delete": {"account"},
}
MAKERS = {"create", "new", "add", "make", "put", "write", "place", "compose", "submit", "do", "execute", "run",
          "perform", "trigger", "confirm", "approve", "complete", "finalize", "start", "close", "cancel",
          "schedule", "queue", "issue", "process", "capture", "accept", "update", "initiate", "authorize",
          "request", "dispatch", "deliver", "transmit", "copy", "push", "merge", "book", "open", "upsert",
          "invoke", "fire", "set"}
# A name with one of these reads or prepares, unless a plain action verb is in it too.
READERS = {"get", "list", "read", "search", "fetch", "find", "query", "view", "show", "describe", "count", "check",
           "preview", "lookup", "retrieve", "download", "inspect", "watch", "poll", "peek", "browse", "summarize",
           "export", "draft", "drafts", "validate", "estimate", "calculate", "lint", "test", "diff", "translate",
           "render", "format", "convert", "analyze", "parse", "transcribe", "info", "status", "history", "stats",
           "speech", "audio", "url", "link", "schema", "template", "templates", "lookup", "resolve", "simulate"}
# Account removal phrased without a delete verb: "close account", "cancel subscription".
ENDERS = {"close", "cancel", "deactivate", "terminate", "unsubscribe", "delete", "remove"}
ENDED = {"account", "accounts", "subscription", "membership", "plan", "order", "booking", "reservation",
         "profile", "user"}
PRIORITY = ("delete", "buy", "send", "post")
LEADS = {"delete": "Delete", "buy": "Pay or buy", "send": "Send", "post": "Post", UNSURE: "Do something"}
COMPOUND = (("delete", "delete"), ("remove", "delete"), ("purge", "delete"), ("send", "send"),
            ("publish", "post"), ("tweet", "post"), ("checkout", "buy"), ("purchase", "buy"), ("pay", "buy"))

# Tools that only change Hermes's own notes. Deleting a memory or a to-do is not deleting a file.
EXEMPT = frozenset(("memory", "todo", "todo_list", "session_search", "request_sign_in", "clarify",
                    "nollie_followup", "text_to_speech", "vision_analyze", "image_generate",
                    # The person's own Board: a worker comments on and hands back its own task.
                    "kanban_comment", "kanban_request_review", "kanban_request_changes", "kanban_complete",
                    "kanban_block", "kanban_unblock", "kanban_heartbeat", "kanban_attach", "kanban_attach_url",
                    "kanban_link", "kanban_create", "kanban_schedule"))
# Calendar, Reminders and Contacts on the Mac (apple_data.py). Every change asks in the tool itself,
# always, with the words the Mac gives it, so these rules would only ask a second time. Reads ask nothing.
APPLE_DATA = frozenset(("calendar_events", "calendar_search", "calendar_add_event", "calendar_change_event",
                        "calendar_delete_event", "reminder_lists", "reminders_open", "reminder_add",
                        "reminder_complete", "reminder_delete", "contacts_search", "contact_add", "contact_change"))
# Paying with a saved card (payments.py). The tool always asks by the Mac's fixed rules, on Ask first's own buy card,
# so these rules would only ask a second time. payment_cards only lists "Visa ending 4242".
PAYMENTS = frozenset(("request_payment", "payment_cards"))
# Hermes tools that only look things up.
LOOKS = frozenset(("web_search", "web_extract", "read_file", "search_files", "skill_view", "skills_list",
                   "browser_snapshot", "browser_get_images", "browser_vision", "browser_navigate", "browser_back",
                   "browser_scroll", "x_search"))
SHELL_TOOLS = frozenset(("terminal", "process", "process_manage"))
CODE_TOOLS = frozenset(("execute_code",))
ACTION_KEYS = ("action", "operation", "op", "verb", "intent", "type", "function", "action_name", "operation_type",
               "event", "kind", "mode")
NAME_KEYS = ("tool_slug", "tool", "tool_name", "action_name", "name", "slug", "function_name")
INNER_ARGS = ("arguments", "params", "input", "args", "parameters", "payload")
CALL_LISTS = ("calls", "tool_calls", "tools", "actions", "batch", "requests")
RECIPIENT_KEYS = {"to", "cc", "bcc", "recipient", "recipients", "recipient_email", "chat_id", "channel",
                  "channel_id", "phone", "phone_number", "number", "attendees", "invitees", "guests", "webhook_url",
                  "email_address", "emailaddress", "user_email", "to_email", "destination_email"}
CONTENT_KEYS = {"body", "text", "message", "content", "html", "subject", "caption", "contents", "msg"}


def _lookup(token, table):
    return any(form in table for form in stems(token))


def kind_of(tokens, lead=True):
    """The kind a run of words names, or None. Plain verbs count; a reading word cancels the ones that are
    nouns too; a noun needs a making verb (or, for a tool's name, to lead it)."""
    tokens = [t for t in tokens if t]
    if not tokens:
        return None
    found, plain = set(), set()
    for kind, verbs in STRONG.items():
        for token in tokens:
            if _lookup(token, verbs):
                found.add(kind)
                if not stems(token) & AMBIGUOUS:
                    plain.add(kind)
    for token in tokens:
        for prefix, kind in COMPOUND:
            if token.startswith(prefix) and len(token) > len(prefix) + 2 and not token.startswith("payload"):
                found.add(kind)
    reading = any(_lookup(t, READERS) for t in tokens)
    if reading:
        found &= plain
    has_maker = any(t in MAKERS for t in tokens)
    if not reading:
        for kind, nouns in NOUNS.items():
            led = lead and _lookup(tokens[0], nouns) and not (len(tokens) > 1 and tokens[1] in ("to", "of"))
            if any(_lookup(t, nouns) for t in tokens) and (has_maker or led):
                found.add(kind)
    if set(tokens) & ENDERS and any(_lookup(t, ENDED) for t in tokens):
        found.add("delete")
    if {"drop"} & set(tokens) and set(tokens) & {"table", "database", "collection", "schema", "bucket", "index"}:
        found.add("delete")
    # A noun that names money beats a plain "send" or "submit": "submit order" pays.
    if "send" in found and any(_lookup(t, NOUNS["buy"]) for t in tokens):
        found.add("buy")
    for kind in PRIORITY:
        if kind in found:
            return kind
    return None


def _stronger(*kinds):
    for kind in PRIORITY + (UNSURE,):
        if kind in kinds:
            return kind
    return None


# Shell commands ---------------------------------------------------------------------------------

SUB = "\x00sub"
_HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
_HERESTRING = re.compile(r"<<<[ \t]*('[^']*'|\"(?:[^\"\\]|\\.)*\"|\S+)")


def _unquote(text):
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return text


def _bodies(text):
    """Here-strings and here-documents taken out of a command: (the command, [(program line, body)])."""
    bodies = []

    def herestring(match):
        before = text[:match.start()]
        bodies.append((before[before.rfind("\n") + 1:], _unquote(match.group(1))))
        return " "
    text = _HERESTRING.sub(herestring, text)
    position = 0
    while True:
        match = _HEREDOC.search(text, position)
        if not match:
            break
        line_start = text.rfind("\n", 0, match.start()) + 1
        owner = text[line_start:match.start()]
        line_end = text.find("\n", match.end())
        if line_end < 0:
            break
        start = line_end + 1
        index, end = start, None
        while index <= len(text):
            newline = text.find("\n", index)
            line = text[index:] if newline < 0 else text[index:newline]
            check = line.lstrip("\t") if match.group(1) else line
            if check.strip() == match.group(3):
                end = (index, len(text) if newline < 0 else newline + 1)
                break
            if newline < 0:
                break
            index = newline + 1
        if end is None:
            bodies.append((owner, text[start:]))
            text = text[:start]
            break
        bodies.append((owner, text[start:end[0]]))
        text = text[:start] + text[end[1]:]
        position = start
    return text, bodies


def _segments(command):
    """Each simple command, quote-aware: split at ; && || | & and new lines outside quotes. The inside
    of $( ) and backticks is a command of its own, even inside double quotes, and leaves a marker."""
    text = str(command or "")
    found, current, inner = [], [], []
    quote = None
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and quote != "'" and i + 1 < len(text):
            current.append(text[i:i + 2])
            i += 2
            continue
        if quote == "'":
            current.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "`" or text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            close = "`" if c == "`" else ")"
            start = i + (1 if c == "`" else 2)
            depth, j = 1, start
            while j < len(text):
                if close == ")" and text.startswith("$(", j):
                    depth += 1
                    j += 2
                    continue
                if text[j] == close:
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            inner.append(text[start:j])
            current.append(SUB)
            i = j + 1
            continue
        if quote == '"':
            current.append(c)
            if c == '"':
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            current.append(c)
            i += 1
            continue
        if c in ";|&\n" and not (c in "|&" and i > 0 and text[i - 1] in "<>") and \
                not (c == "&" and text.startswith(">", i + 1)):
            found.append("".join(current))
            current = []
            i += 2 if text[i:i + 2] in ("&&", "||") else 1
            continue
        current.append(c)
        i += 1
    found.append("".join(current))
    segments = [s.strip() for s in found if s.strip()]
    for piece in inner:
        segments.extend(_segments(piece))
    return segments


# Programs that run another command, and their flags that take a value.
WRAPPERS = {"sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "--user", "--group", "--prompt",
                     "--host", "--role", "--type", "--other-user", "--chdir", "--close-from"},
            "doas": {"-u", "-C"}, "env": {"-u", "-C", "--unset", "--chdir"}, "nohup": set(), "time": {"-f", "-o"},
            "nice": {"-n"}, "ionice": {"-c", "-n", "-p"}, "exec": {"-a"}, "command": set(), "builtin": set(),
            "xargs": {"-I", "-n", "-P", "-s", "-L", "-d", "-E", "-a", "--max-args", "--max-procs", "--delimiter"},
            "caffeinate": {"-t", "-w"}, "timeout": {"-s", "-k", "--signal", "--kill-after"},
            "watch": {"-n", "-d", "--interval"}, "stdbuf": {"-i", "-o", "-e"}, "unbuffer": set(), "arch": set(),
            "parallel": {"-j", "-S", "--jobs"}, "busybox": set(), "chroot": set(), "flock": {"-w", "-E"},
            "systemd-run": set(), "launchctl-asuser": set(), "npx": {"-p", "--package", "-c"},
            "bunx": {"-p", "--package"}, "uvx": {"--from", "--with", "-p", "--python"}, "pipx": set(),
            "dotenv": {"-f", "-e"}, "with-contenv": set(), "op": set(), "aws-vault": set()}
# "<program> <word>" pairs that run the rest: npm exec, uv run, poetry run and friends.
RUNNERS = {("npm", "exec"), ("npm", "x"), ("pnpm", "dlx"), ("pnpm", "exec"), ("yarn", "dlx"), ("yarn", "exec"),
           ("uv", "run"), ("poetry", "run"), ("pipenv", "run"), ("pdm", "run"), ("rye", "run"), ("hatch", "run"),
           ("bundle", "exec"), ("pipx", "run"), ("bun", "x"), ("op", "run"), ("aws-vault", "exec"),
           ("conda", "run"), ("mise", "exec"), ("asdf", "exec"), ("direnv", "exec"), ("nix", "run"),
           ("nix-shell", "--run")}
GNU = {"rm", "rmdir", "unlink", "shred", "find", "mv", "truncate", "xargs", "timeout", "nice", "env", "stdbuf",
       "dd", "sed", "cp"}
SHELLS = frozenset(("sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "busybox-sh"))
INTERPRETERS = {"python": "py", "python3": "py", "python2": "py", "ipython": "py", "pypy": "py", "pypy3": "py",
                "node": "js", "nodejs": "js", "tsx": "js", "ts-node": "js", "ruby": "rb", "perl": "pl",
                "php": "php", "osascript": "as", "swift": "swift", "lua": "lua", "Rscript": "r", "rscript": "r"}
INLINE_LETTERS = {"py": "c", "js": "ep", "rb": "e", "pl": "eE", "php": "r", "as": "e", "swift": "e", "lua": "e",
                  "r": "e"}
VALUE_FLAGS = {"py": {"-W", "-X", "-Q"}, "js": {"-r", "--require", "--import", "--loader", "--input-type",
                                               "--experimental-loader", "--env-file", "-C", "--conditions"},
               "rb": {"-I", "-r", "-E", "-C"}, "pl": {"-I", "-M", "-m"}, "php": {"-c", "-d", "-z"},
               "as": {"-l", "-s"}, "swift": set(), "lua": {"-l"}, "r": set()}
READ_ONLY_PROGRAMS = frozenset(("echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "ack", "cat", "less",
                                "more", "head", "tail", "ls", "wc", "sort", "uniq", "which", "whereis", "man",
                                "file", "stat", "du", "df", "pwd", "true", "false", "test", "[", "date", "jq", "yq",
                                "awk", "cut", "tr", "column", "diff", "cmp", "basename", "dirname", "realpath",
                                "readlink", "type", "help", "history", "tee", "cd", "export", "set", "unset",
                                "alias", "read", "sleep", "wait", "seq", "base64", "md5", "shasum", "sha256sum",
                                "hexdump", "xxd", "od", "strings", "tree", "bat", "fzf", "pbpaste", "uname",
                                "whoami", "id", "hostname", "ps", "top", "pgrep", "lsof", "uptime", "mdfind", "mdls",
                                "plutil", "defaults-read", "sw_vers", "open", "say", "pbcopy", "mkdir", "touch",
                                "cp", "ln", "chmod", "chown", "tar", "zip", "unzip", "gzip", "gunzip", "brew-info"))
MAIL_PROGRAMS = frozenset(("mail", "mailx", "sendmail", "mutt", "neomutt", "msmtp", "msmtpq", "ssmtp", "swaks",
                           "s-nail", "mpack", "telegram-send", "signal-cli", "twilio", "slack", "wacli", "imsg",
                           "apprise", "ntfy", "pushover", "sendxmpp", "sendemail", "himalaya", "aerc", "gam",
                           "mailsend", "blat", "slack-cli", "discord-cli", "tg", "telegram-cli", "matrix-commander"))
PUBLISHERS = {"npm": {"publish"}, "yarn": {"publish", "npm"}, "pnpm": {"publish"}, "bun": {"publish"},
              "deno": {"publish"}, "jsr": {"publish"}, "twine": {"upload"}, "cargo": {"publish"},
              "gem": {"push"}, "docker": {"push"}, "podman": {"push"}, "pod": {"push"}, "poetry": {"publish"},
              "flit": {"publish"}, "hatch": {"publish"}, "uv": {"publish"}, "vsce": {"publish"},
              "ovsx": {"publish"}, "firebase": {"deploy"}, "vercel": set(), "netlify": {"deploy"},
              "fly": {"deploy"}, "flyctl": {"deploy"}, "heroku": {"releases", "deploy"},
              "wrangler": {"publish", "deploy"}, "surge": set(), "gh-pages": set(), "now": set(),
              "railway": {"up", "deploy"}, "render": {"deploy"}, "pulumi": {"up"}, "eb": {"deploy"},
              "serverless": {"deploy"}, "sls": {"deploy"}, "expo": {"publish"}, "eas": {"submit", "update"},
              "fastlane": set(), "xcrun-altool": set(), "goreleaser": set(), "mvn": {"deploy"},
              "gradle": {"publish"}, "dotnet": {"nuget"}, "nuget": {"push"}, "helm": {"push"},
              "ollama": {"push"}, "huggingface-cli": {"upload"}, "hf": {"upload"}}
GH_POSTS = {("pr", "create"), ("pr", "comment"), ("pr", "review"), ("pr", "merge"), ("pr", "ready"),
            ("issue", "create"), ("issue", "comment"), ("release", "create"), ("release", "upload"),
            ("gist", "create"), ("discussion", "create"), ("repo", "create"), ("repo", "fork"),
            ("mr", "create"), ("mr", "note"), ("mr", "merge"), ("mr", "approve"), ("issue", "note"),
            ("snippet", "create"), ("api", "post")}
SMTP_HINT = re.compile(r"(?i)\bsmtp|:(25|465|587|2525)\b|\b(25|465|587|2525)$")
PAY_HOSTS = ("stripe.com", "paypal.com", "squareup.com", "squareupsandbox.com", "braintreegateway.com",
             "adyen.com", "checkout.com", "coinbase.com", "wise.com", "venmo.com", "cash.app", "klarna.com",
             "shopify.com", "paddle.com", "lemonsqueezy.com", "gumroad.com", "revolut.com", "plaid.com",
             "binance.com", "kraken.com", "robinhood.com", "alpaca.markets")
PAY_PATH = re.compile(r"(?i)/(checkout|pay|payments?|purchases?|orders?|charges?|payouts?|transfers?|"
                      r"subscriptions?|invoices?/[^/]+/pay|cart|buy|trades?)(?:/|$)")
SEND_PATH = re.compile(r"(?i)/(send\w*|messages?|mail|emails?|sms|chat\.postmessage|notify|notifications?|invites?|"
                       r"webhooks?|hooks?)(?:/|$|\?)")
POST_PATH = re.compile(r"(?i)/(posts?|comments?|tweets?|statuses|status|publish|media/upload|reactions?|"
                       r"issues|pulls|releases|gists)(?:/|$)")
SQL_DELETE = re.compile(r"(?i)\b(drop\s+(table|database|schema|index|view|user|collection)|delete\s+from|"
                        r"truncate\s+(table\s+)?\w|flushall|flushdb|\.drop\s*\(\s*\))")
TRASH_PATH = re.compile(r"(?i)(\.trash\b|/dev/null|deleted\s*items|\bbin/?$)")
CURL_VALUE = set("XdFTHouAebcwKxmrYyzEDPQUC")


# Shell grammar, not programs: the command after "if", "then" or "do" is the one that runs.
LEADING_KEYWORDS = frozenset(("if", "then", "else", "elif", "do", "while", "until", "!", "{", "(", "time"))
SKIPPED_KEYWORDS = frozenset(("for", "case", "fi", "done", "esac", "}", ")", "function", "select", "in", ";;"))


def _plain_program(word):
    name = word.rsplit("/", 1)[-1]
    name = re.sub(r"@[\w.^~-]+$", "", name)
    match = re.match(r"^(python|pypy|ruby|perl|node|php|lua)(\d+(\.\d+)*)$", name)
    if match:
        name = match.group(1) + ("3" if match.group(1) in ("python", "pypy") else "")
    if name.startswith("g") and name[1:] in GNU:
        name = name[1:]
    if name.endswith("-cli") and name[:-4] in PUBLISHERS:
        name = name[:-4]
    return name


def _split(segment):
    """The words of one simple command with the wrappers in front taken off: sudo, env, xargs, npx..."""
    try:
        parts = shlex.split(segment, posix=True)
    except ValueError:
        parts = segment.split()
    if segment.lstrip().startswith("(("):
        return []  # Arithmetic, not a program.
    for _ in range(8):
        if parts and parts[0].startswith("(") and parts[0] != "(":
            parts[0] = parts[0].lstrip("(")  # A subshell: (cd folder && ...).
        if parts and parts[0].endswith(")") and "(" not in parts[0]:
            parts[0] = parts[0].rstrip(")")  # ... && ls), its last command.
        if parts and parts[0] == "function":
            parts = parts[2:]  # function name { body: the body runs.
        while parts and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", parts[0]) or parts[0] in LEADING_KEYWORDS
                         or re.match(r"^[\w.:-]+\(\)$", parts[0]) or parts[0] in ("()", "")):
            parts.pop(0)
        if not parts or parts[0] in SKIPPED_KEYWORDS:
            return []
        program = _plain_program(parts[0])
        if len(parts) > 1 and (program, parts[1]) in RUNNERS:
            parts = parts[2:]
            while parts and parts[0].startswith("-"):
                parts.pop(0)
            continue
        if program not in WRAPPERS:
            return parts
        if program == "command" and len(parts) > 1 and parts[1] in ("-v", "-V"):
            return ["command"]  # Only says where a program is.
        parts.pop(0)
        takes = WRAPPERS[program]
        while parts and parts[0].startswith("-"):
            flag = parts.pop(0)
            if flag == "--":
                break
            if flag in takes and "=" not in flag and parts:
                parts.pop(0)
        if program == "timeout" and parts and re.match(r"^\d", parts[0]):
            parts.pop(0)
        if program == "time" and parts and parts[0] == "-p":
            parts.pop(0)
    return parts


def _host(url):
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def _url_kind(url, method):
    """What sending something to this address does: buy, send, post or delete."""
    host = _host(url)
    try:
        path = urlsplit(url).path or "/"
    except ValueError:
        path = "/"
    if method == "DELETE":
        return "delete"
    if any(host == h or host.endswith("." + h) for h in PAY_HOSTS) or PAY_PATH.search(path):
        return "buy"
    if POST_PATH.search(path):
        return "post"
    return "send"


def _curl_flags(parts):
    """curl's flags with clusters opened up: -sXPOST -> -s -X POST, -d@file -> -d @file."""
    flags = []
    for part in parts[1:]:
        if part.startswith("--") or not part.startswith("-") or len(part) == 1:
            flags.append(part)
            continue
        letters = part[1:]
        for index, letter in enumerate(letters):
            flags.append("-" + letter)
            if letter in CURL_VALUE:
                rest = letters[index + 1:]
                if rest:
                    flags.append(rest)
                break
    return flags


def _http(parts, piped):
    """curl, wget, httpie and friends: a method, data or a send address means something leaves this computer."""
    program = _plain_program(parts[0])
    flags = _curl_flags(parts) if program in ("curl", "curlie") else parts[1:]
    method, data = None, False
    urls = [p for p in flags if re.match(r"(?i)^(https?|smtps?)://", p)]
    for index, part in enumerate(flags):
        nxt = flags[index + 1] if index + 1 < len(flags) else ""
        if part in ("-X", "--request", "--method"):
            method = nxt.upper()
        elif part.startswith(("--request=", "--method=")):
            method = part.split("=", 1)[1].upper()
        elif part in ("-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii", "-F",
                      "--form", "--form-string", "--json", "-T", "--upload-file", "--post-data", "--post-file",
                      "--body-data", "--body-file", "--mail-rcpt", "--mail-from") or \
                part.startswith(("--data", "--form", "--json=", "--post-", "--body-", "--upload-file=")):
            data = True
        elif program in ("http", "https", "xh", "xhs") and part.upper() in ("POST", "PUT", "PATCH", "DELETE"):
            method = part.upper()
        elif program in ("http", "https", "xh", "xhs") and re.match(r"^[\w.-]+(=|:=|@)", part):
            data = True
    if program in ("http", "https", "xh", "xhs") and piped:
        data = True  # httpie sends what is piped in
    url = urls[0] if urls else ""
    if url.lower().startswith("smtp"):
        return Found("send", f"{program} sends email")
    try:
        path = urlsplit(url).path if url else ""
    except ValueError:
        path = ""
    if method in ("POST", "PUT", "PATCH", "DELETE") or data or SEND_PATH.search(path or "") or \
            PAY_PATH.search(path or ""):
        kind = _url_kind(url, method or "POST")
        where = _host(url) or "a website"
        verb = {"delete": "deletes something at", "buy": "sends a payment request to",
                "post": "posts to", "send": "sends data to"}[kind]
        return Found(kind, f"{program} {verb} {where}")
    return None


def _git(parts):
    rest = parts[1:]
    while rest and rest[0].startswith("-"):
        flag = rest.pop(0)
        if flag in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path") and rest:
            rest.pop(0)
    plain = [p for p in rest if not p.startswith("-")]
    if not plain:
        return None
    sub = plain[0].lower()
    if sub == "push":
        if "--delete" in rest or "-d" in rest or any(p.startswith(":") for p in plain[1:]):
            return Found("delete", "git push deletes a branch or tag on the server")
        return Found("post", "git push publishes commits to a server")
    if sub in ("clean", "rm"):
        return Found("delete", f"git {sub} deletes files")
    if sub == "branch" and {"-d", "-D", "--delete"} & set(rest):
        return Found("delete", "git branch deletes a branch")
    if sub == "tag" and {"-d", "--delete"} & set(rest):
        return Found("delete", "git tag deletes a tag")
    if sub == "reset" and "--hard" in rest:
        return Found("delete", "git reset --hard throws away changes")
    if sub == "stash" and len(plain) > 1 and plain[1] in ("drop", "clear"):
        return Found("delete", "git stash throws away saved changes")
    if sub in ("send-email", "imap-send"):
        return Found("send", f"git {sub} sends email")
    if sub == "restore" or (sub == "checkout" and "--" in rest and plain[1:]):
        return Found("delete", f"git {sub} throws away changes to files")
    if sub == "worktree" and len(plain) > 1 and plain[1] in ("remove", "prune"):
        return Found("delete", "git worktree removes a folder")
    if sub == "filter-branch" or sub == "filter-repo":
        return Found("delete", f"git {sub} rewrites and can drop history")
    if sub == "remote" and len(plain) > 1 and plain[1] in ("remove", "rm"):
        return None
    return None


def _forge(program, parts):
    """gh and glab: GitHub and GitLab."""
    rest = parts[1:]
    plain = [p.lower() for p in rest if not p.startswith("-")]
    joined = [r.lower() for r in rest]
    if len(plain) < 2:
        return None
    group, verb = plain[0], plain[1]
    group = {"mr": "pr"}.get(group, group)
    site = "GitHub" if program == "gh" else "GitLab"
    if verb == "delete" or (group == "repo" and verb in ("delete", "archive")) or \
            (group == "release" and verb == "delete-asset"):
        return Found("delete", f"{program} {plain[0]} {verb} deletes it on {site}")
    if (group, verb) in GH_POSTS:
        return Found("post", f"{program} {plain[0]} {verb} posts on {site}")
    if verb in ("close", "merge", "edit", "reopen", "lock") and \
            any(f in joined for f in ("--comment", "-c", "--body", "-b", "--body-file")):
        return Found("post", f"{program} {plain[0]} {verb} posts a comment on {site}")
    if group == "repo" and verb == "edit" and any(r.startswith("--visibility") for r in joined) and \
            "public" in joined + [r.split("=", 1)[-1] for r in joined]:
        return Found("post", f"{program} repo edit makes a repository public")
    if group == "release" and verb == "edit" and any(r in ("--draft=false", "--prerelease=false") for r in joined):
        return Found("post", f"{program} release edit publishes a release")
    if group == "api":
        method = None
        for index, part in enumerate(rest):
            if part in ("-X", "--method") and index + 1 < len(rest):
                method = rest[index + 1].upper()
            elif part.startswith("-X") and len(part) > 2:
                method = part[2:].upper()
            elif part.startswith("--method="):
                method = part.split("=", 1)[1].upper()
        fields = any(p in ("-f", "-F", "--field", "--raw-field", "--input") or p.startswith(("-f", "-F"))
                     for p in rest)
        if method == "DELETE":
            return Found("delete", f"{program} api deletes something on {site}")
        if method in ("POST", "PUT", "PATCH") or fields:
            return Found("post", f"{program} api changes something on {site}")
    return None


def _osascript(text):
    lowered = text.lower()
    if re.search(r"\bempty\b[^\n]*\btrash\b", lowered) or re.search(r"\bmove\b[^\n]*\bto\b[^\n]*(trash|deleted)",
                                                                     lowered):
        return Found("delete", "the script moves things to the Trash")
    if re.search(r"\bdelete\b", lowered):
        return Found("delete", "the script can delete")
    if re.search(r"\b(send|outgoing message|imessage)\b", lowered) or 'application "messages"' in lowered:
        return Found("send", "the script can send a message")
    if "system events" in lowered and re.search(r"\b(keystroke|key code|click)\b", lowered):
        return Found(UNSURE, "the script presses keys or buttons in another app")
    return None


def _token_found(program, tokens):
    """A command's own words, for CLIs with subcommands: kubectl delete, aws ses send-email, stripe ... pay."""
    for token in tokens:
        lowered = token.lower()
        if not lowered or any(c in lowered for c in "/~*= \t\n.@") or len(lowered) > 64:
            continue
        flag = lowered.startswith("-")
        bare = lowered.lstrip("-")
        pieces = [p for p in re.split(r"[-_:]+", bare) if p] or [bare]
        joined = words(token.lstrip("-"))
        if any(p in STRONG["delete"] for p in pieces) or bare.startswith(("delete", "remove", "purge")) or \
                any(p in STRONG["delete"] for p in joined):
            return Found("delete", f"{program} {token} deletes")
        if "reset" in pieces and (set(pieces) & {"db", "database", "pg"} or flag is False and
                                  program in ("supabase", "prisma", "rails", "heroku", "rake")):
            return Found("delete", f"{program} {token} wipes a database")
        if flag:
            continue
        first = pieces[0]
        for kind in ("buy", "send", "post"):
            if first in STRONG[kind] - {"text", "email", "mail", "order", "release", "merge", "share",
                                        "comment", "react", "respond", "invite", "tip", "bid", "rent"}:
                return Found(kind, f"{program} {token}")
        if bare.startswith("send") and len(bare) > 6:
            return Found("send", f"{program} {token} sends")
        if bare.startswith("pay") and not bare.startswith("payload") and len(bare) > 5:
            return Found("buy", f"{program} {token} pays")
    return None


# Programs whose every use here is a fixed job on this computer. Their risky uses (rm, a mail server, SQL DROP)
# are caught above; anything not here and not read above asks.
KNOWN_PROGRAMS = frozenset((
    "ffmpeg", "ffprobe", "ffplay", "sips", "convert", "magick", "identify", "mogrify", "montage", "pandoc",
    "pdftotext", "pdfinfo", "pdftoppm", "pdfimages", "pdfunite", "pdfseparate", "qpdf", "exiftool", "tesseract",
    "textutil", "afconvert", "afinfo", "screencapture", "bc", "expr", "cal", "ncal", "units", "numfmt", "iconv",
    "sed", "xmllint", "yt-dlp", "youtube-dl", "gallery-dl", "csvlook", "csvcut", "csvstat", "in2csv", "xsv",
    "qsv", "mlr", "glow", "black", "ruff", "isort", "flake8", "pylint", "mypy", "pyright", "pytest", "eslint",
    "prettier", "tsc", "jest", "vitest", "mocha", "shellcheck", "swiftlint", "swiftformat", "rustfmt", "gofmt",
    "clang-format", "rustc", "gcc", "g++", "clang", "clang++", "cc", "c++", "swiftc", "kotlinc", "javac", "ping",
    "dig", "nslookup", "host", "traceroute", "whois", "ifconfig", "scutil", "system_profiler", "sysctl", "vm_stat",
    "iostat", "ioreg", "pmset", "lsblk", "mount", "log", "nano", "vim", "vi", "emacs", "code", "subl", "clear",
    "reset", "stty", "tput", "printenv", "locale", "kill", "killall", "pkill", "local", "declare", "typeset",
    "readonly", "let", "shift", "return", "exit", "trap", "break", "continue", "getopts", "umask", "ulimit",
    "hash", "jobs", "fg", "bg", "disown", ":", "mv", "rsync", "scp", "sftp", "dd", "crontab", "diskutil",
    "tmutil", "defaults", "openssl", "sqlite3", "psql", "mysql", "mariadb", "redis-cli", "mongosh", "mongo",
    "duckdb", "sqlcmd", "clickhouse-client", "cqlsh", "vite", "next", "webpack", "rollup", "esbuild", "parcel",
    "tsup", "tailwindcss", "postcss", "sass", "babel", "swc", "astro", "nuxt", "react-scripts", "storybook",
    "venv", "json.tool", "http.server", "unittest", "pydoc", "timeit", "cProfile", "doctest", "py_compile",
    "compileall", "zipfile", "tarfile", "gzip", "base64", "uuid", "calendar", "platform", "sysconfig", "site",
    "ensurepip", "xattr", "mdutil", "lipo", "otool", "nm", "codesign", "spctl", "plutil", "pkgutil", "sw_vers",
    "caffeinate", "pbcopy", "shasum", "md5sum", "sha1sum", "sha512sum", "cksum", "unxz", "xz", "bzip2",
    "bunzip2", "7z", "7za", "unrar", "ditto", "install", "rename", "column", "fold", "fmt", "nl", "paste", "join",
    "comm", "split", "csplit", "rev", "tac", "shuf", "yes", "envsubst", "gettext", "sleep", "say", "osacompile",
    "[[", "]]", "shopt", "setopt", "unsetopt", "dirs", "times", "caller", "compgen", "complete", "readarray",
    "mapfile", "unalias", "noglob", "emulate", "autoload", "zmodload", "print", "whence", "rehash", "groups",
    "who", "w", "last", "users", "nproc", "getconf", "afplay", "qlmanage", "mdimport", "textutil", "iconutil",
    "soffice", "libreoffice", "marker", "marker_single", "pdftk", "mutool", "img2pdf", "ocrmypdf", "optipng",
    "pngquant", "jpegoptim", "cwebp", "dwebp", "heif-convert", "lame", "flac", "sox", "whisper", "whisper-cpp"))
# Words that say a command only looks, as a program's first words: "brew list", "docker ps", "kubectl get".
LOOKING_SUBCOMMANDS = {"list", "ls", "get", "show", "describe", "view", "info", "status", "logs", "log", "inspect",
                       "version", "help", "search", "cat", "diff", "check", "outdated", "doctor", "whoami", "ps",
                       "images", "top", "tree", "deps", "home", "prefix", "which", "where", "query", "read",
                       "history", "stats", "plan", "explain", "find", "print", "env", "freeze", "leaves", "fetch",
                       "config-get", "current", "uses", "why", "lint", "test", "build", "check-config", "validate",
                       "format", "fmt", "vet", "clippy", "doc", "docs", "bench", "metadata", "audit",
                       "today", "tomorrow", "yesterday", "week", "month", "all", "overdue", "upcoming", "recent",
                       "latest", "now", "next", "items", "count", "summary", "usage", "health", "ping"}
HELP_FLAGS = {"-h", "--help", "--version", "-v", "-V", "-version", "--usage"}
# Runners of package scripts: what the script says is read from package.json.
SCRIPT_RUNNERS = {"npm": {"run", "run-script", "rum", "urn", "start", "stop", "restart", "test", "t", "tst"},
                  "pnpm": {"run", "start", "test", "t"}, "yarn": {"run", "start", "test"},
                  "bun": {"run", "start", "test"}}
INSTALLERS = {"npm": {"install", "i", "ci", "add", "update", "up", "rebuild", "link", "exec", "x", "init", "create"},
              "pnpm": {"install", "i", "add", "update", "up", "rebuild", "link", "exec", "dlx", "create", "init"},
              "yarn": {"install", "add", "upgrade", "up", "dlx", "exec", "create", "init", "link"},
              "bun": {"install", "i", "add", "update", "x", "create", "init", "link"},
              "brew": {"install", "reinstall", "upgrade", "tap", "bundle", "link", "services"},
              "pip": {"install", "download", "wheel"}, "pip3": {"install", "download", "wheel"},
              "gem": {"install", "update"}, "cargo": {"install"}, "go": {"install", "get"},
              "uv": {"pip", "add", "sync", "tool"}, "poetry": {"install", "add", "update"},
              "pipenv": {"install", "update"}, "mas": {"install", "upgrade", "purchase"}}
# Build tools and the words that only build, test or check here. Anything else they run asks.
BUILDERS = {"cargo": {"build", "test", "check", "fmt", "clippy", "doc", "bench", "tree", "metadata", "new", "init",
                      "clean", "update", "fetch", "search", "add", "remove"},
            "go": {"build", "test", "vet", "fmt", "list", "doc", "version", "env", "mod", "work", "generate"},
            "swift": {"build", "test", "package", "--version", "format"},
            "dotnet": {"build", "test", "format", "--info", "--version", "list", "restore", "new"},
            "xcodebuild": set(), "gradle": {"build", "test", "check", "assemble", "compileJava", "tasks", "help"},
            "gradlew": {"build", "test", "check", "assemble", "compileJava", "tasks", "help"},
            "mvn": {"compile", "test", "package", "verify", "validate", "clean", "install"},
            "mvnw": {"compile", "test", "package", "verify", "validate", "clean", "install"},
            "deno": {"check", "fmt", "lint", "test", "info", "doc", "bench", "compile"}}
RUN_ELSEWHERE = {"cargo": {"run"}, "go": {"run"}, "swift": {"run"}, "dotnet": {"run"}, "deno": {"task"},
                 "gradle": set(), "gradlew": set(), "mvn": set(), "mvnw": set()}
OTHER_RUNNERS = frozenset(("rake", "task", "invoke", "nox", "tox", "mage", "ninja", "bazel", "bazelisk", "buck",
                           "buck2", "ant", "sbt", "mix", "lein", "scons", "meson", "cmake", "turbo", "nx", "lerna",
                           "concurrently", "foreman", "overmind", "honcho", "pm2", "nodemon", "watchexec",
                           "entr", "fswatch", "parallel", "docker-compose", "tilt", "skaffold"))
SYSTEM_FOLDERS = ("/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/local/bin/",
                  "/opt/homebrew/bin/", "/opt/homebrew/sbin/", "/opt/local/bin/", "/System/", "/Library/Apple/",
                  "/Library/Developer/CommandLineTools/", "/Applications/Xcode")


def _unknown_program(program, plain, rest):
    """A program the rules don't know: it passes when its own words say it only looks, and asks otherwise."""
    if set(rest) & HELP_FLAGS:
        return None
    if not rest:
        return Found(UNSURE, f"Nollie doesn't know what {program} does, so it asks")
    if not plain:
        flag = re.sub(r"^-+", "", rest[0]).lower()
        if flag.startswith(("list", "get", "show", "print", "info", "status", "version")):
            return None  # networksetup -listallhardwareports, softwareupdate --list
    # Subcommands as written, and their parts: "files:get", "calendar-list", "notes.search".
    first = [w for p in plain[:3] for w in [p.lower()] + re.split(r"[:._-]+", p.lower()) if w]
    looks = any(w in LOOKING_SUBCOMMANDS for w in first)
    changes = any(w in CHANGE_VERBS or w in INSTALLER_WORDS for w in first if w not in LOOKING_SUBCOMMANDS)
    if looks and not changes:
        return None
    return Found(UNSURE, f"Nollie doesn't know what {program} {' '.join(plain[:2])}".rstrip() + " does, so it asks")


INSTALLER_WORDS = {"install", "add", "upgrade", "update", "run", "exec", "start", "up", "apply", "deploy",
                   "push", "sync", "login", "auth"}


def _json_text(text):
    try:
        document = json.loads(text)
    except (TypeError, ValueError):
        return None
    return document if isinstance(document, dict) else None


def _folder_flag(rest, names):
    for index, part in enumerate(rest):
        for name in names:
            if part == name and index + 1 < len(rest):
                return rest[index + 1]
            if part.startswith(name + "="):
                return part.split("=", 1)[1]
    return None


def _join(cwd, folder):
    if not folder:
        return cwd
    folder = os.path.expanduser(folder)
    return folder if os.path.isabs(folder) or not cwd else os.path.join(cwd, folder)


def _package_script(program, rest, plain, depth, cwd, read_file):
    """npm run, yarn and friends: the script's own command from package.json, read with the same rules."""
    lowered = [p.lower() for p in plain]
    if program in SCRIPT_RUNNERS and lowered and lowered[0] in SCRIPT_RUNNERS[program]:
        name = plain[1] if lowered[0] in ("run", "run-script", "rum", "urn") and len(plain) > 1 else \
            {"t": "test", "tst": "test"}.get(lowered[0], lowered[0])
        if lowered[0] in ("run", "run-script", "rum", "urn") and len(plain) < 2:
            return None  # npm run alone lists the scripts.
    elif program in ("yarn", "pnpm") and plain and not (set(lowered[:1]) & INSTALLERS.get(program, set())) and \
            lowered[0] not in LOOKING_SUBCOMMANDS | {"why", "info", "config", "cache", "workspaces", "dlx"}:
        name = plain[0]  # yarn build: a script by name.
    else:
        return False
    if read_file is None:
        return Found(UNSURE, f"Nollie can't read what the {name} script does")
    if depth >= 3:
        return Found(UNSURE, "it runs scripts inside scripts")
    folder = _join(cwd, _folder_flag(rest, ("--prefix", "-C", "--dir", "--cwd")))
    document = _json_text(read_file("package.json", folder))
    scripts = document.get("scripts") if document else None
    if not isinstance(scripts, dict) or not isinstance(scripts.get(name), str):
        return Found(UNSURE, f"Nollie can't read what the {name} script does")
    unsure = None
    for step in (f"pre{name}", name, f"post{name}"):
        command = scripts.get(step)
        if isinstance(command, str) and command.strip():
            found = shell_found(command, depth + 1, folder, read_file)
            if found and found.kind != UNSURE:
                return Found(found.kind, f"its {step} script: {found.why}")
            unsure = unsure or found
    return unsure


_MAKE_VARIABLE = re.compile(r"\$[({]([A-Za-z_][A-Za-z0-9_.-]*)[)}]")


def _make_rules(text):
    """(variables, {target: (prerequisites, recipe lines)}, default target) from a plain Makefile."""
    text = re.sub(r"\\\n[ \t]*", " ", text)
    variables, rules, default, current = {}, {}, None, None
    for line in text.split("\n"):
        if line.startswith("\t"):
            if current:
                for target in current:
                    rules[target][1].append(line[1:])
            continue
        stripped = line.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue
        assignment = re.match(r"^\s*(?:export\s+|override\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*(?:::=|:=|\?=|\+=|!=|=)\s*(.*)$",
                              stripped)
        if assignment and not re.match(r"^[^=]*[^:]:[^=]", stripped.split("=", 1)[0] + "="):
            variables.setdefault(assignment.group(1), assignment.group(2).strip())
            current = None
            continue
        rule = re.match(r"^([^:=]+?)\s*::?\s*([^=]*)$", stripped)
        if rule:
            targets = rule.group(1).split()
            current = targets
            for target in targets:
                rules.setdefault(target, ([], []))[0].extend(rule.group(2).split(";")[0].split())
                if default is None and not target.startswith(".") and "%" not in target:
                    default = target
            if ";" in rule.group(2):
                for target in targets:
                    rules[target][1].append(rule.group(2).split(";", 1)[1])
            continue
        current = None
    return variables, rules, default


def _make_found(program, rest, depth, cwd, read_file):
    """make: the recipes for the targets asked for, read with the same rules. A Makefile it can't read asks."""
    if read_file is None:
        return Found(UNSURE, "Nollie can't read the Makefile to see what it runs")
    if depth >= 3:
        return Found(UNSURE, "it runs scripts inside scripts")
    folder = _join(cwd, _folder_flag(rest, ("-C", "--directory")))
    named = _folder_flag(rest, ("-f", "--file", "--makefile"))
    text = None
    for name in ([named] if named else ["GNUmakefile", "makefile", "Makefile"]):
        text = read_file(name, folder)
        if text is not None:
            break
    if text is None:
        return Found(UNSURE, "Nollie can't read the Makefile to see what it runs")
    variables, rules, default = _make_rules(text)
    takes = {"-C", "--directory", "-f", "--file", "--makefile", "-j", "--jobs", "-l", "-o", "-W", "-I"}
    goals, skip = [], False
    for part in rest:
        if skip:
            skip = False
            continue
        if part in takes:
            skip = True
            continue
        if part.startswith("-"):
            continue
        if "=" in part:
            key, value = part.split("=", 1)
            variables[key] = value
            continue
        goals.append(part)
    goals = goals or ([default] if default else [])
    if not goals:
        return None
    seen, queue, lines = set(), list(goals), []
    while queue and len(seen) < 64:
        target = queue.pop(0)
        if target in seen:
            continue
        seen.add(target)
        if target not in rules:
            if any("%" in name for name in rules) or not os.path.exists(_join(folder, target) or target):
                return Found(UNSURE, f"Nollie can't read what make {target} runs")
            continue
        prerequisites, recipe = rules[target]
        queue.extend(prerequisites)
        lines.extend((target, line) for line in recipe)
    unsure = None
    for target, line in lines:
        command = re.sub(r"^[@+\-\s]+", "", line)
        for _ in range(4):
            command = _MAKE_VARIABLE.sub(lambda m: variables.get(m.group(1), m.group(0)) if m.group(1) != "MAKE"
                                         else "make", command)
        command = command.replace("$@", target).replace("$<", "x").replace("$^", "x").replace("$*", "x")
        command = command.replace("$$", "$")
        found = shell_found(command, depth + 1, folder, read_file)
        if found and found.kind != UNSURE:
            return Found(found.kind, f"make {target}: {found.why}")
        unsure = unsure or found
    return unsure


def _builder_found(program, plain, rest):
    lowered = [p.lower() for p in plain]
    if program == "xcodebuild":
        return None if not set(lowered) & {"archive", "-exportarchive", "exportarchive"} or \
            not any(p.startswith("-exportOptionsPlist") for p in rest) else \
            Found(UNSURE, "xcodebuild exports an app, which can upload it")
    if lowered and lowered[0] in RUN_ELSEWHERE.get(program, set()):
        return Found(UNSURE, f"{program} {lowered[0]} runs a program Nollie can't read")
    if not lowered or lowered[0] in BUILDERS[program] or set(rest) & HELP_FLAGS:
        return None
    return Found(UNSURE, f"Nollie doesn't know what {program} {plain[0]} runs, so it asks")


def _program_found(parts, depth, cwd, read_file, piped, bodies):
    program = _plain_program(parts[0])
    rest = list(parts[1:])
    plain = [p for p in rest if not p.startswith("-")]
    lowered = [p.lower() for p in plain]
    if SUB in parts[0] or parts[0].startswith("$") or program in ("eval",):
        if program == "eval":
            inner = " ".join(rest)
            if SUB not in inner and "$" not in inner:
                return shell_found(inner, depth + 1, cwd, read_file)
        return Found(UNSURE, "the program it runs is chosen when it runs")
    if program in SHELLS:
        for index, part in enumerate(rest):
            if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", part):
                code = rest[index + 1] if index + 1 < len(rest) else ""
                if SUB in code:
                    return Found(UNSURE, "the command it runs is built when it runs")
                return shell_found(code, depth + 1, cwd, read_file) if depth < 3 else None
        script = next((p for p in rest if not p.startswith("-")), None)
        if script and script != "-":
            return _script_found(script, "sh", cwd, read_file, depth)
        return _stdin(bodies, "sh", piped)
    if program in ("source", "."):
        return _script_found(plain[0], "sh", cwd, read_file, depth) if plain else None
    if program == "deno":
        if lowered[:1] == ["eval"] and len(plain) > 1:
            return code_found(plain[1], "js")
        if lowered[:1] == ["run"] and len(plain) > 1:
            return _script_found(plain[1], "js", cwd, read_file, depth)
        if lowered[:1] == ["publish"]:
            return Found("post", "deno publish publishes")
    if program == "bun":
        if lowered[:1] == ["publish"]:
            return Found("post", "bun publish publishes")
        if lowered[:1] == ["run"] and len(plain) > 1 and re.search(r"\.(m?[jt]sx?)$", plain[1]):
            return _script_found(plain[1], "js", cwd, read_file, depth)
        if plain and re.search(r"\.(m?[jt]sx?)$", plain[0]):
            return _script_found(plain[0], "js", cwd, read_file, depth)
    if program == "swift" and lowered[:1] and lowered[0] in BUILDERS["swift"] | RUN_ELSEWHERE["swift"]:
        return _builder_found(program, plain, rest)
    if program in INTERPRETERS:
        language = INTERPRETERS[program]
        letters = INLINE_LETTERS.get(language, "")
        takes = VALUE_FLAGS.get(language, set())
        index = 0
        while index < len(rest):
            part = rest[index]
            if part in ("--eval", "--print") or part.startswith(("--eval=", "--print=")):
                code = part.split("=", 1)[1] if "=" in part else (rest[index + 1] if index + 1 < len(rest) else "")
                return code_found(code, language)
            if re.match(r"^-[A-Za-z]+$", part) and part[-1] in letters and part not in takes:
                code = rest[index + 1] if index + 1 < len(rest) else ""
                if SUB in code:
                    return Found(UNSURE, "the code it runs is built when it runs")
                return code_found(code, language)
            if part == "-m" and language == "py" and index + 1 < len(rest):
                return _program_found(rest[index + 1:], depth + 1, cwd, read_file, piped, bodies)
            if part in takes:
                index += 2
                continue
            if part.startswith("-") and part != "-":
                index += 1
                continue
            if part == "-":
                return _stdin(bodies, language, piped)
            return _script_found(part, language, cwd, read_file, depth)
        return _stdin(bodies, language, piped)
    if program in ("rm", "rmdir", "unlink", "shred", "srm", "trash", "trash-put", "trash-rm", "trash-empty",
                   "wipefs", "truncate", "rimraf", "del", "deltree"):
        return Found("delete", f"{program} deletes files")
    if program.startswith("mkfs") or program in ("dropdb", "dropuser"):
        return Found("delete", f"{program} erases data")
    if program == "dd" and any(p.startswith("of=") for p in rest):
        return Found("delete", "dd writes over a disk or file")
    if program == "crontab" and any(re.match(r"^-[a-z]*r[a-z]*$", p) for p in rest):
        return Found("delete", "crontab -r deletes every schedule")
    if program in ("find", "fd", "fdfind"):
        if "-delete" in rest or any(p in ("-exec", "-execdir", "-ok", "-x", "--exec", "-X", "--exec-batch")
                                    and i + 1 < len(rest) and _plain_program(rest[i + 1]) in
                                    ("rm", "rmdir", "unlink", "shred", "trash") for i, p in enumerate(rest)):
            return Found("delete", f"{program} deletes the files it finds")
        return None
    if program == "mv" and plain and TRASH_PATH.search(plain[-1]):
        return Found("delete", "mv moves files to the Trash")
    if program == "rsync" and any(p.startswith("--delete") or p == "--remove-source-files" for p in rest):
        return Found("delete", "rsync deletes files")
    if program in MAIL_PROGRAMS:
        return Found("send", f"{program} sends messages")
    if program in ("nc", "ncat", "netcat", "telnet", "socat") and any(SMTP_HINT.search(p) for p in rest):
        return Found("send", f"{program} talks to a mail server")
    if program == "openssl" and lowered[:1] == ["s_client"] and any(SMTP_HINT.search(p) for p in rest):
        return Found("send", "openssl talks to a mail server")
    if program in ("curl", "curlie", "wget", "http", "https", "xh", "xhs", "httpie", "aria2c"):
        return _http(parts, piped or any("<" in s for s in parts[1:]))
    if program in ("scp", "sftp", "rsync") and any(re.match(r"^[^/\s]*[A-Za-z0-9]:", p) for p in plain):
        return Found("send", f"{program} sends files to another computer")
    if program == "git":
        return _git(parts)
    if program == "jj" and lowered[:2] == ["git", "push"] or program == "hg" and lowered[:1] == ["push"] or \
            program == "svn" and lowered[:1] in (["commit"], ["ci"]):
        return Found("post", f"{program} publishes commits to a server")
    if program == "hg" and lowered[:1] and lowered[0] in ("strip", "purge", "remove", "rm"):
        return Found("delete", f"hg {lowered[0]} deletes")
    if program in ("gh", "glab"):
        found = _forge(program, parts)
        if found:
            return found
    if program in ("docker", "podman") and "--push" in rest:
        return Found("post", f"{program} pushes an image")
    if program in ("docker", "podman", "docker-compose") and ("down" in lowered) and \
            ({"-v", "--volumes", "--rmi"} & set(rest)):
        return Found("delete", f"{program} down deletes volumes")
    if program in PUBLISHERS and (not PUBLISHERS[program] or set(lowered) & PUBLISHERS[program]):
        return Found("post", f"{program} publishes")
    if program == "stripe" and plain:
        return Found("buy", "stripe can move money")
    if program in ("aws", "gsutil", "gcloud") and lowered[:2] in (["s3", "rb"], ["rb"]) or program == "gsutil" and \
            lowered[:1] == ["rb"]:
        return Found("delete", f"{program} removes a bucket")
    if program in ("rclone",) and lowered[:1] and lowered[0] in ("sync", "move", "moveto", "purge", "delete",
                                                                 "deletefile", "rmdir", "rmdirs", "cleanup"):
        return Found("delete", f"rclone {lowered[0]} can delete files")
    if program == "gsutil" and "rsync" in lowered and "-d" in rest:
        return Found("delete", "gsutil rsync -d deletes files")
    if program in ("aws",) and "sync" in lowered and "--delete" in rest:
        return Found("delete", "aws s3 sync --delete deletes files")
    if program == "osascript":
        return _osascript(" ".join(rest)) or code_found(" ".join(rest), "as")
    if program == "open" and any(p.lower().startswith(("shortcuts://", "sms:", "imessage:", "facetime:"))
                                 for p in plain):
        return Found("send", "the link runs a Shortcut or starts a message")
    if program == "shortcuts" and lowered[:1] == ["run"]:
        return Found("send", "a Shortcut can send, post or pay")
    if program in ("sqlite3", "psql", "mysql", "mariadb", "redis-cli", "mongosh", "mongo", "duckdb", "sqlcmd",
                   "clickhouse-client", "cqlsh") and SQL_DELETE.search(" ".join(rest)):
        return Found("delete", f"{program} deletes data")
    if program == "redis-cli" and lowered[:1] and lowered[0] in ("del", "unlink", "flushall", "flushdb"):
        return Found("delete", "redis-cli deletes data")
    if program == "diskutil" and any(w.startswith(("erase", "zero", "secureerase", "deletevolume", "partition",
                                                   "apfs", "reformat")) for w in lowered):
        return Found("delete", "diskutil erases a disk")
    if program == "tmutil" and lowered[:1] and lowered[0].startswith("delete"):
        return Found("delete", "tmutil deletes backups")
    if program in ("defaults", "security", "launchctl", "dscl", "sysadminctl", "profiles") and \
            any(w in ("delete", "remove", "-deleteuser", "bootout", "unload") or w.startswith("delete-")
                for w in lowered + [r.lower() for r in rest]):
        return Found("delete", f"{program} deletes a setting, item or account")
    script = parts[0]
    if script.startswith(("./", "../", "~/")) or re.search(r"\.(py|sh|bash|zsh|m?js|ts|rb|pl|php|command)$", script) \
            or (script.startswith("/") and not script.startswith(SYSTEM_FOLDERS)):
        language = {"py": "py", "js": "js", "mjs": "js", "ts": "js", "rb": "rb", "pl": "pl", "php": "php"}.get(
            script.rsplit(".", 1)[-1], "sh")
        return _script_found(script, language, cwd, read_file, depth)
    if program in ("ssh", "mosh", "autossh"):
        remote = _remote_command(rest)
        return shell_found(remote, depth + 1, None, None) if remote and depth < 3 else None
    if program in SCRIPT_RUNNERS or program in ("yarn", "pnpm"):
        found = _package_script(program, rest, plain, depth, cwd, read_file)
        if found is not False:
            return found
    if program in ("make", "gmake", "just"):
        return _make_found(program, rest, depth, cwd, read_file) if program != "just" else \
            _just_found(rest, depth, cwd, read_file)
    if program in INSTALLERS and lowered[:1] and lowered[0] in INSTALLERS[program]:
        return Found(UNSURE, f"{program} {lowered[0]} fetches and runs other people's code")
    if program in BUILDERS:
        return _builder_found(program, plain, rest)
    if program in OTHER_RUNNERS:
        return None if set(rest) & HELP_FLAGS else Found(UNSURE, f"Nollie can't read what {program} runs")
    stream = next((p for p in rest if STREAM_URL.match(p)), None) if program not in READ_ONLY_PROGRAMS else None
    if stream:
        return Found("post", f"{program} sends a live stream to {_host(stream) or 'another computer'}")
    if program not in READ_ONLY_PROGRAMS:
        found = _token_found(program, plain[:4] + [r for r in rest if r.startswith("-") and len(r) > 2])
        if found:
            return found
        if SQL_DELETE.search(" ".join(rest)):
            return Found("delete", f"{program} deletes data")
        if program not in KNOWN_PROGRAMS and program not in HANDLED_PROGRAMS:
            return _unknown_program(program, plain, rest)
    return None


# Programs with rules of their own above: what they do otherwise is local, or caught by those rules.
HANDLED_PROGRAMS = frozenset(("find", "fd", "fdfind", "git", "gh", "glab", "jj", "hg", "svn", "osascript", "open",
                              "shortcuts", "stripe", "cd", "pushd", "popd", "source", ".", "eval", "exec",
                              "command", "builtin", "nc", "ncat", "netcat", "telnet", "socat"))
# Addresses a program can send a live stream or files to: ffmpeg -f flv rtmp://... broadcasts.
STREAM_URL = re.compile(r"(?i)^(rtmps?|rtsp|srt|udp|tcp|ftp|ftps|sftp|icecast)://")
SSH_VALUE_FLAGS = {"-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q",
                   "-R", "-S", "-W", "-w", "-B"}


def _remote_command(rest):
    """The command ssh runs on the other computer, after its options and the host."""
    index, host = 0, None
    while index < len(rest):
        part = rest[index]
        if part in SSH_VALUE_FLAGS:
            index += 2
            continue
        if part.startswith("-"):
            index += 1
            continue
        host = index
        break
    return " ".join(rest[host + 1:]) if host is not None else ""


def _just_found(rest, depth, cwd, read_file):
    """just: the recipe's lines from the justfile, read with the same rules."""
    if read_file is None or depth >= 3:
        return Found(UNSURE, "Nollie can't read the justfile to see what it runs")
    folder = _join(cwd, _folder_flag(rest, ("-d", "--working-directory")))
    named = _folder_flag(rest, ("-f", "--justfile"))
    text = None
    for name in ([named] if named else ["justfile", "Justfile", ".justfile"]):
        text = read_file(name, folder)
        if text is not None:
            break
    if text is None:
        return Found(UNSURE, "Nollie can't read the justfile to see what it runs")
    if set(rest) & ({"-l", "--list", "--summary", "--show", "-s", "--dump"} | HELP_FLAGS):
        return None
    recipes, default, current = {}, None, None
    for line in text.split("\n"):
        if line[:1] in (" ", "\t") and current:
            recipes[current].append(line.strip())
            continue
        match = re.match(r"^@?([A-Za-z_][A-Za-z0-9_-]*)[^:=]*:(?!=)\s*(.*)$", line)
        if match:
            current = match.group(1)
            recipes[current] = []
            for dependency in match.group(2).split():
                recipes[current].append(f"just {dependency}")
            default = default or current
        elif line.strip() and not line.startswith("#"):
            current = None
    goal = next((p for p in rest if not p.startswith("-")), default)
    if goal not in recipes:
        return Found(UNSURE, f"Nollie can't read what just {goal or ''} runs".replace("  ", " "))
    lines = [line.lstrip("@-") for line in recipes[goal] if line and not line.startswith("#")]
    body = "\n".join(lines)
    if lines and lines[0].startswith("#!"):
        return code_found(body, "py" if "python" in lines[0] else "js" if "node" in lines[0] else "sh")
    if "{{" in body:
        return Found(UNSURE, f"just {goal} builds its commands when it runs")
    return shell_found(body, depth + 1, folder, read_file)


def _stdin(bodies, language, piped):
    """A shell or interpreter reading what is piped in: the text, when it is written right there, is read."""
    for owner, body in bodies:
        found = (shell_found(body) if language == "sh" else None) or code_found(body, language)
        if found:
            return found
    if bodies and not piped:
        return None
    if piped:
        return Found(UNSURE, "it runs whatever is piped into it")
    return None


def _script_found(path, language, cwd, read_file, depth):
    """A script file run by name: its contents are read with the same rules. One that can't be read asks."""
    if read_file is None:
        return None
    if depth >= 3:
        return Found(UNSURE, "it runs scripts inside scripts")
    if SUB in path or path.startswith("$"):
        return Found(UNSURE, "the script it runs is chosen when it runs")
    text = read_file(path, cwd)
    if text is None:
        return Found(UNSURE, f"Nollie can't read {path} to see what it does")
    if "\x00" in text[:8192]:
        return Found(UNSURE, f"{path} is a compiled program, which Nollie can't read")
    shebang = re.match(r"^#!\s*(\S+)(?:\s+(\S+))?", text)
    if shebang and language == "sh":
        named = _plain_program(shebang.group(2) if shebang.group(1).endswith("/env") and shebang.group(2)
                               else shebang.group(1))
        if named in INTERPRETERS:
            language = INTERPRETERS[named]
        elif named not in SHELLS:
            return Found(UNSURE, f"Nollie can't read what {path} runs with {named}")
    if language == "sh":
        return shell_found(text, depth + 1, cwd, read_file)
    return code_found(text, language) or (shell_found(text, depth + 1, cwd, read_file) if language == "sh" else None)


# The files checker for this call's shell rules: set by ``classify`` and left out on other computers.
FILES = contextvars.ContextVar("nollie_ask_first_files", default=None)


def shell_found(command, depth=0, cwd=None, read_file=None):
    """The first send, buy, post or delete a shell command does, or None. Can't tell: UNSURE."""
    text, bodies = _bodies(str(command or ""))
    segments = _segments(text)
    unsure = None
    files = FILES.get() if read_file is not None else None
    for index, segment in enumerate(segments):
        parts = _split(segment)
        if not parts:
            continue
        piped = index > 0 and _piped_into(text, segment)
        own = [b for b in bodies if segment and b[0].strip() and b[0].strip() in segment] or \
            ([b for b in bodies] if len(segments) == 1 else [])
        found = _program_found(parts, depth, cwd, read_file, piped, own)
        if found and found.kind != UNSURE:
            return found
        written = overwrites_found(parts, cwd, files)
        if written and written.kind != UNSURE:
            return written
        unsure = unsure or found or written
    for owner, body in bodies:
        found = code_found(body)
        if found and found.kind != UNSURE:
            return found
    if SQL_DELETE.search(text) and not all(_plain_program((_split(s) or [""])[0]) in READ_ONLY_PROGRAMS
                                           for s in segments):
        return Found("delete", "the command deletes data")
    if unsure:
        # Something it can't read: but echo 'rm -rf x' | sh reads what is echoed first.
        if "piped into" in unsure.why:
            for segment in segments:
                for part in _split(segment)[1:]:
                    found = shell_found(part, depth + 1, cwd, None) if depth < 3 and " " in part else None
                    found = found or code_found(part)
                    if found and found.kind != UNSURE:
                        return found
        return unsure
    return None


def _piped_into(text, segment):
    position = text.find(segment)
    if position <= 0:
        return False
    before = text[:position].rstrip()
    return before.endswith("|") and not before.endswith("||")


CODE_RULES = (
    ("delete", re.compile(r"\bos\.(remove|unlink|rmdir|removedirs)\s*\(|\brmtree\s*\(|\bremove_tree\b|"
                          r"\.(unlink|rmdir|rmSync|unlinkSync|rmdirSync|rm|emptyDir|emptyDirSync|trash|destroy|"
                          r"purge|expunge)\s*\(|\bsend2trash\b|\brimraf\b|\bDeno\.remove\b|\bFileUtils\.(rm|remove)|"
                          r"\bFile\.delete\b|\bremoveItem\b|\btrashItem\b|\bunlink\s*(\(|glob\b|['\"$@])|"
                          r"\brm\s+-[a-zA-Z]*[rf]|\bempty\s+trash\b|\.Trash\b|\\\\?Deleted\b|"
                          r"from\s+(os|shutil|pathlib)\s+import\s+[^\n]*\b(remove|unlink|rmdir|rmtree|removedirs)\b|"
                          r"\.delete(_\w+)?\s*\(|\.remove_(file|dir|directory|tree|object|objects|item|user|account|"
                          r"member|bucket|blob|message|email|repo|branch|folder)\s*\(|"
                          r"\.drop_(table|database|collection|schema|index|bucket)\s*\(|"
                          r"if_exists\s*=\s*['\"]replace['\"]"), "the code deletes something"),
    ("delete", SQL_DELETE, "the code deletes data"),
    ("delete", re.compile(r"(?i)method\s*[:=]\s*['\"]delete['\"]|\.(request|fetch)\s*\(\s*['\"]delete['\"]"),
     "the code deletes something on a server"),
    ("buy", re.compile(r"\bstripe\.(PaymentIntent|Charge|Payout|Transfer|Invoice|Subscription|checkout|Refund|"
                       r"PaymentLink)\b|\bpaypalrestsdk\b|\bbraintree\.\w|from\s+square\b|\bsquare\.client\b|"
                       r"\bcreate_payment\s*\(|\bPaymentIntent\b|\.charges\.create|\.payouts\.create|"
                       r"\b(create_\w*order|submit_order|place_\w*order|order_(buy|sell)\w*|create_market_\w+|"
                       r"create_limit_\w+|send_money|send_payment|make_payment|buy_\w+|sell_\w+)\s*\(|"
                       r"\bcheckout\s*\(|/checkout\b|checkout\.sessions?\b|\bpurchase\s*\(|"
                       r"\.(send_?[tT]ransaction|transferFrom|sendTransaction)\s*\(|\bccxt\b[\s\S]*\border\b"),
     "the code can pay or buy"),
    ("post", re.compile(r"\btweepy\b|create_?tweet|update_?status|\bpraw\b[\s\S]*\.submit\s*\(|\.publish\s*\(|"
                        r"\bstatus_post\b|\bsend_post\b|\.create_(issue|comment|pull|release|gist|post|status)\s*\("),
     "the code posts"),
    ("send", re.compile(r"(?i)\bsmtplib\b|\bsendmail\b|\bsend_?message\b|\bsend_?mail\b|\bnodemailer\b|\btwilio\b|"
                        r"\bslack_sdk\b|chat_?post_?message|\btelegram\b|\bsend_email\b|\byagmail\b|\bsendgrid\b|"
                        r"\bresend\b|\bmailgun\b|\bexchangelib\b|\bO365\b|\bpywhatkit\b|Net::SMTP|"
                        r"Net::HTTP\.post|\bpost_form\b|\.deliver(_now|_later)?\b|\boutgoing\s+message\b|"
                        r"\bimessage\b|tell\s+application\s+\"messages\"|send_?updates\s*=\s*['\"](all|external)|"
                        r"\.messages(\(\))?\.send\s*\("), "the code sends a message"),
    ("send", re.compile(r"\.send(_\w+)?\s*\(|\.(post|put|patch)\s*\(|"
                        r"(?i:\.(request|urlopen|fetch)\s*\(\s*['\"](post|put|patch)['\"])|"
                        r"(?i:method\s*[:=]\s*['\"](post|put|patch)['\"])|\burlopen\s*\([^)]*data\s*=|"
                        r"\bRequest\s*\([^)]*\bdata\s*=|\bXMLHttpRequest\b|\bsocket\.send|\.sendall\s*\("),
     "the code sends data somewhere"),
)
CLICKS_IN_CODE = re.compile(r"\.(click|dblclick|tap|submit|requestSubmit)\s*\(|press\s*\(\s*['\"](enter|return)|"
                            r"\bpyautogui\b|\bpynput\b|\bCGEvent|\bkeyboard\.press|\bclick_at_xy\s*\(|"
                            r"\bdispatchEvent\s*\(|Input\.dispatch|\bsend_keys\s*\(|\.type\s*\([^)]*\\n", re.I)
CLICK_TARGET = re.compile(r"\.(click|tap)\s*\(\s*['\"`]([^'\"`]{1,160})")
SHELL_IN_CODE = re.compile(r"\b(subprocess\.\w+|os\.system|os\.popen|os\.exec\w*|execSync|execFileSync|"
                           r"spawnSync|spawn|execFile|Popen|check_output|check_call|system|exec|`)\s*\(?\s*"
                           r"(\[[^\]]{0,600}\]|[rfb]?(['\"`]).{0,600}?\3)(\s*,\s*\[[^\]]{0,600}\])?", re.S)
# Calls that surely start another program, unlike a regular expression's .exec().
RUNS_PROGRAM = re.compile(r"^(subprocess\.\w+|os\.system|os\.popen|os\.exec\w*|execSync|execFileSync|spawnSync|"
                          r"spawn|execFile|Popen|check_output|check_call|system)$")
RUNS_CHOSEN = re.compile(r"\b(subprocess\.(run|call|Popen|check_output|check_call|getoutput|getstatusoutput)|"
                         r"os\.(system|popen|exec[lv]p?e?|spawn[lv]p?e?)|child_process\.(exec|execSync|spawn|spawnSync)|"
                         r"execSync|spawnSync|execFileSync)\s*\(\s*(?![\s'\"`\[]|[rfbu]['\"]|\[\s*['\"])")
_STRINGS = re.compile(r"'([^'\\]*(?:\\.[^'\\]*)*)'|\"([^\"\\]*(?:\\.[^\"\\]*)*)\"|`([^`]*)`")


def _method_call(text, match):
    """``something.exec(...)`` or ``something.system(...)`` is a method of that something, not a program."""
    return match.group(1) in ("exec", "system", "spawn") and text[max(0, match.start() - 1):match.start()] == "."


def _llm_call(text, match):
    after = text[match.end():match.end() + 300]
    return bool(re.search(r"\bmodel\s*[=:]", after)) or bool(re.search(r"anthropic|openai", text[:2000], re.I))


def code_found(code, language="py"):
    """The first send, buy, post or delete a piece of code does, by pattern. Comments count too."""
    text = str(code or "")
    if not text.strip():
        return None
    if language == "as" or re.search(r"(?i)tell\s+application\s", text):
        found = _osascript(text)
        if found:
            return found
    for kind, pattern, why in CODE_RULES:
        for match in pattern.finditer(text):
            if kind == "send" and ".messages" in match.group(0) and _llm_call(text, match):
                continue
            return Found(kind, why)
    unsure = None
    for match in SHELL_IN_CODE.finditer(text):
        pieces = [a or b or c for a, b, c in _STRINGS.findall(match.group(2) + (match.group(4) or ""))]
        if match.group(2).startswith("[") and re.match(r"\[\s*sys\.executable\b", match.group(2)):
            pieces.insert(0, "python3")  # The same Python the code runs in.
        command = " ".join(shlex.quote(p) if " " in p and len(pieces) > 1 else p for p in pieces) \
            if match.group(2).startswith("[") or match.group(4) else (pieces[0] if pieces else "")
        found = shell_found(command) if command else None
        if found and found.kind != UNSURE:
            return found
        if found and RUNS_PROGRAM.match(match.group(1)) and not _method_call(text, match):
            unsure = unsure or Found(UNSURE, f"the code runs a program: {found.why}")
    chosen = RUNS_CHOSEN.search(text)
    if chosen:
        unsure = unsure or Found(UNSURE, "the code runs a program chosen when it runs")
    target = CLICK_TARGET.search(text)
    if target:
        kind = button_kind(re.sub(r"^(text|button|role)=", "", target.group(2)))
        if kind:
            return Found(kind, f"the code presses \u201c{target.group(2)[:60]}\u201d")
    if CLICKS_IN_CODE.search(text):
        return Found(UNSURE, "the code clicks or presses keys, and Nollie can't read what on")
    return unsure


# Arguments to plain words -----------------------------------------------------------------------

SECRET_KEYS = re.compile(r"(?i)(pass(word|wd|code|phrase)?|secret|token|api_?key|auth|cookie|credential|cvv|cvc|"
                         r"card_?number|\bpin\b|^pin$|otp|private_?key)")


def _value(value, limit=VALUE_LIMIT):
    if isinstance(value, str):
        text = value.strip()
    else:
        try:
            text = json.dumps(value, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            text = str(value)
    return text if len(text) <= limit else text[:limit - 1] + "\u2026"


def detail_lines(args, skip=()):
    """Every argument, one per line, so the card shows the whole action. Secrets stay hidden."""
    lines = []
    for key, value in (args or {}).items():
        if key in skip or str(key).startswith("_") or value in (None, "", [], {}):
            continue
        shown = "[hidden]" if SECRET_KEYS.search(str(key)) else _value(_hide_nested(value))
        lines.append(f"{key}: {shown}")
    return lines


def _hide_nested(value):
    if isinstance(value, dict):
        return {k: ("[hidden]" if SECRET_KEYS.search(str(k)) else _hide_nested(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [_hide_nested(v) for v in value]
    return value


def _tool_words(tool):
    parts = str(tool).split("__")
    if len(parts) >= 3 and parts[0] in ("mcp", "connectors"):
        return parts[1].replace("_", " ").replace("-", " ").strip(), "__".join(parts[2:])
    return "", str(tool)


def _summary(first, lines, *, limit=SUMMARY_LIMIT):
    text = "\n".join([first] + [line for line in lines if line])
    return text if limit is None or len(text) <= limit else text[:limit - 1] + "\u2026"


def _walk(value, depth=0):
    """(key, value) pairs at any depth, for arguments nested in objects and lists."""
    if depth > 6:
        return
    if isinstance(value, dict):
        for key, item in value.items():
            yield str(key), item
            yield from _walk(item, depth + 1)
    elif isinstance(value, list):
        for item in value[:200]:
            yield from _walk(item, depth + 1)


def _args_found(tokens, args):
    """What the arguments themselves say, whatever the tool is called."""
    keys = {}
    for key, value in _walk(args):
        keys.setdefault(re.sub(r"[^a-z]", "", key.lower()), []).append(value)
    lowered = {k.replace("_", "") for k in keys}

    def truthy(name):
        return any(v is True or (isinstance(v, str) and v.lower() in ("true", "yes", "1")) for v in keys.get(name, []))
    if truthy("trashed") or truthy("intrash") or truthy("istrashed") or truthy("deleted") or truthy("permanent"):
        return Found("delete", "it moves something to the Trash")
    for name in ("addlabelids", "labelids", "addlabels", "labels", "folder", "destination", "destinationfolder",
                 "target", "to", "newpath", "destinationpath", "dest", "moveto", "mailbox"):
        for value in keys.get(name, []):
            values = value if isinstance(value, list) else [value]
            for item in values:
                if isinstance(item, str) and (item.upper() in ("TRASH", "BIN", "DELETEDITEMS", "DELETED ITEMS") or
                                              (TRASH_PATH.search(item) and set(tokens) & {"move", "rename", "mv",
                                                                                          "modify", "update"})):
                    return Found("delete", "it moves something to the Trash")
    sends_updates = [v for k in ("sendupdates", "sendnotifications", "notify", "sendinvites", "sendemail")
                     for v in keys.get(k, [])]
    if any(v is True or (isinstance(v, str) and v.lower() not in ("none", "false", "no", "0", "")) for v in sends_updates):
        return Found("send", "it sends invitations or updates to people")
    if any(isinstance(v, list) and v for k in ("attendees", "invitees", "guests") for v in keys.get(k, [])):
        return Found("send", "it invites people")
    for name in ("isbuy", "side", "leverage"):
        for value in keys.get(name, []):
            if name != "side" or (isinstance(value, str) and value.lower() in ("buy", "sell", "long", "short")):
                return Found("buy", "it trades")
    drafting = set(tokens) & {"draft", "drafts", "preview", "validate", "estimate", "translate", "format", "parse",
                              "search", "list", "get", "read", "summarize", "count", "analyze", "render", "speech"}
    if not drafting and lowered & RECIPIENT_KEYS and lowered & CONTENT_KEYS:
        return Found("send", "it has someone to send to and something to say")
    for name in ("sql", "statement", "query", "command", "cmd", "script", "code"):
        for value in keys.get(name, []):
            if isinstance(value, str) and SQL_DELETE.search(value) and (name != "query" or set(tokens) & {
                    "sql", "db", "database", "execute", "run", "query", "exec", "supabase", "postgres", "mysql",
                    "sqlite"}):
                return Found("delete", "the query deletes data")
    return None


def _inner_calls(tool, args):
    """Calls wrapped in another: Hermes's bridge, connector batches, and tools that run a named tool."""
    if tool in ("tool_call", "connectors__execute"):
        calls = args.get("calls")
        if isinstance(calls, str):
            try:
                calls = json.loads(calls)
            except ValueError:
                return None
        if not isinstance(calls, list):
            calls = [{"name": args.get("name") or args.get("tool") or args.get("tool_name"),
                      "arguments": args.get("arguments") or args.get("args") or args.get("input")}]
        found = []
        for call in calls:
            if not isinstance(call, dict):
                return None
            name = call.get("name") or call.get("tool") or call.get("tool_name")
            inner = call.get("arguments") or call.get("args") or call.get("input") or {}
            if isinstance(inner, str):
                try:
                    inner = json.loads(inner)
                except ValueError:
                    inner = {"text": inner}
            if not isinstance(name, str) or not name:
                return None
            found.append((name, inner if isinstance(inner, dict) else {"value": inner}))
        return found or None
    found = []
    name = next((args[k] for k in NAME_KEYS if isinstance(args.get(k), str) and args.get(k).strip()), None)
    inner = next((args[k] for k in INNER_ARGS if isinstance(args.get(k), (dict, str))), None)
    if name and inner is not None and name != tool:
        if isinstance(inner, str):
            try:
                inner = json.loads(inner)
            except ValueError:
                inner = {"text": inner}
        found.append((name, inner if isinstance(inner, dict) else {"value": inner}))
    for key in CALL_LISTS:
        items = args.get(key)
        if isinstance(items, list):
            for item in items:
                if isinstance(item, dict):
                    inner_name = next((item[k] for k in NAME_KEYS if isinstance(item.get(k), str)), None)
                    inner_args = next((item[k] for k in INNER_ARGS if isinstance(item.get(k), dict)), item)
                    if inner_name:
                        found.append((inner_name, inner_args))
    return found or None


# Other servers' tools ---------------------------------------------------------------------------

# An MCP or connector tool passes only when its own name plainly reads: one of these verbs, and no verb that
# changes something ahead of it. Everything else asks, whatever the model says it is for.
LOOK_VERBS = {"get", "list", "read", "search", "fetch", "find", "query", "view", "show", "describe", "count",
              "lookup", "retrieve", "browse", "inspect", "preview", "peek", "summarize", "summarise", "explain",
              "download", "validate", "estimate", "calculate", "diff", "compare", "analyze", "analyse",
              "translate", "render", "parse", "transcribe", "ping", "whoami", "screenshot", "snapshot",
              "navigate", "goto", "scroll", "hover", "wait", "zoom", "resize", "highlight", "emulate", "watch",
              "poll", "lint", "test", "simulate", "info", "status", "stats", "history", "schema", "resolve"}
CHANGE_VERBS = {"create", "add", "make", "put", "write", "place", "compose", "submit", "execute", "run", "perform",
                "trigger", "confirm", "approve", "complete", "finalize", "start", "close", "cancel", "schedule",
                "queue", "accept", "update", "upsert", "initiate", "authorize", "dispatch", "deliver", "transmit",
                "copy", "merge", "invoke", "fire", "set", "edit", "modify", "change", "save", "move", "rename",
                "sync", "import", "archive", "unarchive", "mark", "label", "star", "unstar", "pin", "unpin", "flag",
                "enable", "disable", "toggle", "assign", "unassign", "apply", "install", "exec", "call", "stop",
                "kill", "restart", "launch", "lock", "unlock", "reject", "decline", "clone", "fork", "insert",
                "append", "patch", "replace", "reset", "clear", "empty", "configure", "register", "login",
                "logout", "signin", "signup", "join", "leave", "follow", "unfollow", "like", "unlike", "unblock",
                "mute", "unmute", "connect", "disconnect", "unlink", "attach", "detach", "grant", "revoke", "book",
                "process", "upload", "click", "press", "fill", "drag", "drop", "type", "do", "export",
                "reopen", "open", "new", "handle", "respond", "answer", "vote", "rate", "review", "claim",
                "redeem", "activate", "convert", "format", "generate"} | {
    verb for kind, verbs in STRONG.items() for verb in verbs}
# Pages and tabs in a browser: opening, closing and choosing one only looks.
PAGE_WORDS = {"new", "open", "close", "select", "switch", "list", "get", "page", "pages", "tab", "tabs", "window",
              "windows", "browser", "frame", "focus"}
FILLER = {"api", "v1", "v2", "v3", "tool", "mcp", "the", "a", "an", "by", "for", "of", "to", "from", "in", "on",
          "with", "all", "my"}
JOINS = {"and", "or", "then", "plus"}
OVERWRITES = {"replace", "overwrite", "upsert"}
DRAFTS = {"draft", "drafts"}
# Servers with their own rules: Nollie Computer asks on the Mac, and Cua's computers are read above.
OWN_SERVERS = ("mcp__nollie_mac__", "mcp__cua__")


def _plainly_reads(tokens):
    """True when a tool's name only looks: a reading verb, and no changing verb before it."""
    tokens = [t for t in tokens if t not in FILLER]
    if not tokens:
        return False
    if set(tokens) <= PAGE_WORDS and set(tokens) & {"page", "pages", "tab", "tabs", "window", "windows", "frame"}:
        return True
    looked, reads = False, any(_lookup(t, LOOK_VERBS) for t in tokens)
    for token in tokens:
        if reads and token in AMBIGUOUS:
            continue  # A noun as often as a verb: "post" in "search posts", "order" in "get order".
        if token in JOINS:
            looked = False  # What follows "and" is a verb of its own.
            continue
        if _lookup(token, LOOK_VERBS):
            looked = True
            continue
        if token in OVERWRITES or (not looked and token in CHANGE_VERBS):
            return False
    return reads


def _first_sentence(text):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return re.split(r"(?<=[.!?])\s|\n", text, maxsplit=1)[0][:240]


def _description_kind(sentence):
    """The kind the first sentence of a description names: a plain action verb anywhere, a verb that is a noun
    as often only as its first word ("Post a message"), or a making verb leading a noun ("Create an order")."""
    tokens = words(sentence)
    if not tokens:
        return None
    found = set()
    for kind in PRIORITY:
        if any(stems(t) & (STRONG[kind] - AMBIGUOUS) for t in tokens) or stems(tokens[0]) & STRONG[kind]:
            found.add(kind)
        if tokens[0] in MAKERS and any(_lookup(t, NOUNS[kind]) for t in tokens[1:6]):
            found.add(kind)
    if set(tokens) & ENDERS and any(_lookup(t, ENDED) for t in tokens):
        found.add("delete")
    return _stronger(*found)


def _schema_found(tokens, info):
    """What a tool says it does when it was registered: its own description and the fields it takes."""
    kind = _description_kind(_first_sentence(info.get("description")))
    if kind:
        return Found(kind, "its own description says so")
    properties = (info.get("parameters") or {}).get("properties") if isinstance(info.get("parameters"), dict) else None
    if isinstance(properties, dict) and not set(tokens) & DRAFTS:
        keys = {re.sub(r"[^a-z]", "", str(k).lower()) for k in properties}
        if keys & RECIPIENT_KEYS and keys & CONTENT_KEYS:
            return Found("send", "it takes someone to send to and something to say")
    return None


def _http_reads(tokens, args):
    """A plain web request tool asked for a page: GET or HEAD, and nothing sent with it."""
    web = {"http", "https", "curl", "url", "web", "api"}
    if not set(tokens) & web or not (set(tokens) & {"request", "fetch", "get", "call"} or set(tokens) <= web):
        return False
    method = str(args.get("method") or args.get("http_method") or args.get("httpMethod") or "GET").upper()
    sent = any(args.get(k) not in (None, "", {}, []) for k in ("body", "data", "json", "form", "payload", "content"))
    return method in ("GET", "HEAD", "OPTIONS") and not sent


def other_server_found(tool, tokens, args, info):
    """An MCP or connector tool the name rules found nothing in: asks unless it plainly only reads."""
    if info:
        found = _schema_found(tokens, info)
        if found:
            return found
    if _plainly_reads(tokens) or set(tokens) & DRAFTS or _http_reads(tokens, args):
        return None
    return Found(UNSURE, "Nollie can't tell from its name that it only looks things up")


def other_server(tool):
    return str(tool).startswith(("mcp__", "connectors__")) and tool != "connectors__execute" and \
        not str(tool).startswith(OWN_SERVERS)


# Screens ----------------------------------------------------------------------------------------

# Buttons that send, buy, post or delete, read from the screen where a click lands.
BUTTONS = {
    "delete": ("delete", "remove", "trash", "erase", "discard", "empty trash", "delete account", "close account",
               "deactivate", "unsubscribe", "cancel subscription", "move to bin", "bin", "delete forever",
               "remove from cart"),
    "buy": ("buy", "pay", "checkout", "check out", "place order", "purchase", "subscribe", "donate", "order now",
            "complete order", "confirm order", "submit order", "confirm payment", "pay now", "buy now", "book now",
            "reserve", "transfer", "send money", "add funds", "upgrade", "start trial", "start free trial", "rent",
            "bid", "proceed to checkout", "confirm and pay", "confirm & pay", "complete purchase", "order", "book",
            "top up", "cash out", "place your order", "apple pay", "google pay", "buy with apple pay"),
    "send": ("send", "reply", "reply all", "forward", "submit", "send now", "invite", "share", "confirm",
             "save and send", "schedule send", "send email", "send message", "accept invitation", "accept invite",
             "rsvp", "connect", "apply", "respond", "request"),
    "post": ("post", "publish", "tweet", "post reply", "comment", "upload", "share post", "repost", "retweet",
             "go live", "boost", "toot", "add comment", "post comment", "submit review", "pull request",
             "create pull request", "merge", "merge pull request", "deploy", "publish now", "post it"),
}
# Words a button only needs to contain: "Send 3 photos", "Pay $24.00".
BUTTON_WORDS = {
    "delete": {"delete", "remove", "trash", "erase", "discard", "deactivate", "unsubscribe", "bin", "uninstall",
               "empty", "unsend", "terminate", "destroy", "purge", "wipe", "eliminar", "borrar", "supprimer",
               "löschen", "elimina", "excluir", "apagar", "verwijderen"},
    "buy": {"buy", "pay", "checkout", "purchase", "subscribe", "donate", "transfer", "upgrade", "reserve", "rent",
            "bid", "payment", "booking", "reservation", "renew", "tip", "topup", "trial", "swap", "withdraw",
            "deposit", "cashout", "comprar", "acheter", "kaufen", "pagar", "payer", "bezahlen", "acquista", "paga",
            "kopen", "betalen"},
    "send": {"send", "reply", "forward", "submit", "invite", "share", "rsvp", "enviar", "envoyer", "senden",
             "invia", "inviare", "verzenden", "skicka"},
    "post": {"post", "publish", "tweet", "comment", "upload", "repost", "retweet", "toot", "merge", "deploy",
             "upvote", "publicar", "publier", "veröffentlichen", "pubblica", "posten"},
}
SCREEN_WORDS = {w for ws in BUTTON_WORDS.values() for w in ws} | {"message", "imessage", "chat", "dm", "order",
                                                                   "book"}
UNREADABLE = object()


def button_kind(label):
    """The kind a button label names, by exact phrase or word. Never guessed beyond the words."""
    text = re.sub(r"\s+", " ", str(label or "")).strip().lower()
    text = re.sub(r"^[^\w$£€]+|[^\w$£€]+$", "", text)
    if not text:
        return None
    text = text[:LABEL_LIMIT]
    for kind in PRIORITY:
        if text in BUTTONS[kind]:
            return kind
    tokens = set(re.findall(r"[^\W\d_]+", text))
    if tokens & ENDERS and tokens & ENDED:
        return "delete"
    for kind in PRIORITY:
        if tokens & BUTTON_WORDS[kind]:
            return kind
    return None


def screen_has_risk(text):
    """True when risky words show anywhere on screen, so a Return there may press one."""
    return bool(set(re.findall(r"[^\W\d_]+", str(text or "").lower())) & SCREEN_WORDS)


def _button(label):
    text = _one_line(label or "")
    return text[:60] if text else None


CLICKS = {"computer_click", "computer_double_click", "computer_mouse_up", "computer_left_click",
          "computer_right_click", "computer_triple_click", "click", "double_click", "left_click", "right_click",
          "triple_click", "middle_click", "tap", "browser_click", "browser_double_click", "mouse_up",
          "click_element", "press_button"}
KEYS = {"computer_key", "computer_key_down", "computer_keypress", "computer_press_key", "computer_hotkey", "key",
        "key_down", "keypress", "press_key", "hotkey", "press", "browser_press", "browser_press_key", "send_keys",
        "keyboard_press"}
TYPES = {"computer_type", "type", "type_text", "browser_type", "fill", "browser_fill", "fill_form",
         "browser_fill_form", "set_value", "input_text"}
DIALOGS = {"browser_dialog", "browser_handle_dialog", "handle_dialog", "accept_dialog"}
SCRIPTS = {"browser_console", "browser_exec", "browser_cdp", "browser_evaluate", "evaluate", "javascript_tool",
           "execute_script", "run_javascript", "javascript_exec", "eval_js", "execute_javascript", "run_js"}
PRESSES = {"computer_accessibility_act", "accessibility_act", "ax_press", "perform_action"}
MODIFIERS = {"cmd": "cmd", "command": "cmd", "meta": "cmd", "super": "cmd", "win": "cmd", "windows": "cmd",
             "controlormeta": "cmd", "cmdorctrl": "cmd", "commandorcontrol": "cmd", "ctrl": "ctrl",
             "control": "ctrl", "alt": "alt", "option": "alt", "opt": "alt", "shift": "shift", "fn": "fn"}
ENTER = {"enter", "return", "kpenter", "numpadenter", "\n", "\r", "kp_enter", "numpad_enter", "keypadenter"}
DELETE_KEYS = {"delete", "backspace", "del", "forwarddelete", "back_space"}


def parse_keys(args):
    """(modifiers, key) from any of the ways tools name keys: "cmd+return", ["command", "enter"], "Cmd-Enter"."""
    raw = None
    for name in ("keys", "key", "hotkey", "combo", "shortcut", "text"):
        value = args.get(name)
        if isinstance(value, (list, tuple)) and value:
            raw = [str(v) for v in value]
            break
        if isinstance(value, str) and value:
            raw = value
            break
    if raw is None:
        return set(), ""
    if isinstance(raw, str):
        if raw in ("\n", "\r", "\r\n"):
            return set(), "enter"
        # As Hermes reads a combo: split at + and -, modifiers anywhere, the last other part is the key.
        pieces = [p for p in re.split(r"\s*[+-]\s*", raw.strip()) if p] or [raw.strip()]
    else:
        pieces = [p for piece in raw for p in (re.split(r"\s*[+-]\s*", piece.strip()) if len(piece.strip()) > 1
                                               else [piece]) if p]
    mods, key = set(), ""
    for piece in pieces:
        name = piece.strip().lower().replace(" ", "")
        if name in MODIFIERS:
            mods.add(MODIFIERS[name])
        elif name:
            key = name.replace("-", "").replace("_", "") if name not in ("\n", "\r") else "enter"
    if key in ENTER or key in ("kpenter", "numpadenter"):
        key = "enter"
    if key in DELETE_KEYS or key == "backspace":
        key = "delete"
    return mods, key


def _types_return(text):
    return isinstance(text, str) and ("\n" in text or "\r" in text)


def _computer_name(tool, args, *, include_id=True):
    if tool == "computer_use":
        return "this Mac"
    if tool.startswith("browser_"):
        return "the browser"
    name = args.get("sandbox") or args.get("space") or args.get("computer")
    if isinstance(name, str) and name.strip():
        return f"its computer ({name})" if include_id else "its computer"
    return "its computer" if tool.startswith("mcp__cua") else "a computer or browser"


def _said(args):
    """What the helper says it is pressing. Never used to let a click through: only to word the card."""
    for key in ("element", "selector", "target", "label", "description", "name", "text"):
        value = args.get(key)
        if isinstance(value, str) and value.strip() and not value.strip().isdigit():
            return _one_line(value)[:120]
    return None


def computer_action(short, tool, args, where, screen):
    """A click, key or typed Return on a computer or page: held when the screen shows it may send, buy, post
    or delete. ``screen`` reads the label under a click and the words on screen, or answers UNREADABLE, and a
    click Nollie can't read asks."""
    if short in PRESSES:
        action = str(args.get("action") or "").lower()
        if action in ("focus", "scroll_to_visible", "show_menu", "scrolltovisible") or (
                action == "set_value" and not _types_return(args.get("value"))):
            return None
        return Action(UNSURE, _summary(f"Press item {args.get('element_id') or args.get('element')} on {where}.",
                                       ["Nollie can't read which button that is, so it asks first."]))
    if short in CLICKS:
        label = screen.label_at(tool, args)
        said = _said(args)
        if label is UNREADABLE or label is None or not str(label).strip():
            lines = ["Nollie couldn't read a label there, so it asks first."]
            if said:
                lines.append(f"The helper says it is: \u201c{said}\u201d.")
            kind = button_kind(said) if said else None
            return Action(kind or UNSURE, _summary(f"Click on {where}.", lines))
        kind = button_kind(label)
        if kind:
            return Action(kind, f"Press \u201c{_button(label)}\u201d on {where}.", _button(label))
        return _unsaid_press(label, tool, args, where, screen)
    if short in KEYS or short in TYPES:
        text = args.get("text") if short in TYPES else None
        if short in TYPES:
            value = text if text is not None else args.get("value")
            if not (_types_return(value) or args.get("submit") is True or args.get("press_enter") is True):
                return None
            mods, key, text = set(), "enter", value
        else:
            mods, key = parse_keys(args)
        if key == "enter" and mods & {"cmd", "ctrl"}:
            return Action("send", _summary(f"Press {'+'.join(sorted(mods))}+Return on {where}.",
                                           ["In most apps this sends."]))
        if key == "delete" and ("cmd" in mods or mods == {"shift"}):
            return Action("delete", _summary(f"Press {'+'.join(sorted(mods))}+Delete on {where}.",
                                             ["In most apps this deletes."]))
        if (key == "d" and mods == {"cmd", "shift"}) or (key == "s" and mods == {"alt"}):
            return Action("send", _summary(f"Press {'+'.join(sorted(mods))}+{key.upper()} on {where}.",
                                           ["In Mail and Outlook this sends."]))
        if key == "enter" and not mods - {"shift"} and "shift" not in mods:
            seen = screen.text(tool, args)
            if seen is UNREADABLE or screen_has_risk(seen):
                typed = f"Type \u201c{_value(text, 200)}\u201d and press Return on {where}." if \
                    isinstance(text, str) and text.strip() else f"Press Return on {where}."
                why = (["Nollie couldn't read the screen, so it asks first."] if seen is UNREADABLE else
                       ["Return can press a Send, Pay, Post or Delete button showing there."])
                return Action("send" if seen is not UNREADABLE else UNSURE, _summary(typed, why))
        return None
    if short in DIALOGS:
        action = str(args.get("action") or args.get("accept") or "").lower()
        if action in ("accept", "true", "ok", "confirm", "yes") or args.get("accept") is True:
            return Action(UNSURE, _summary(f"Say yes to a question on {where}.",
                                           ["Pages ask before they send, pay or delete, so Nollie asks first."]))
        return None
    if short in SCRIPTS:
        method = str(args.get("method") or "")
        if method.startswith("Input.dispatch") or (method == "Page.handleJavaScriptDialog" and (
                (args.get("params") or {}).get("accept") is True)):
            return Action(UNSURE, _summary(f"Press or click on {where} ({method}).",
                                           ["Nollie can't read what it presses, so it asks first."]))
        code = next((args.get(k) for k in ("expression", "code", "script", "text", "function", "js", "source")
                     if args.get(k)), None) or args.get("params")
        if code:
            text = code if isinstance(code, str) else json.dumps(code)
            found = code_found(text, "js")
            if found:
                return Action(found.kind, _summary(f"Run a script on {where}:", [_value(text, 1000),
                                                                                 f"Why Nollie asks: {found.why}."]))
        return None
    return None


# Buttons that say only "go ahead". What they do is in the window, sheet or page around them.
NEUTRAL_WORDS = {"ok", "okay", "continue", "done", "confirm", "yes", "next", "proceed", "accept", "agree",
                 "allow", "got", "it", "finish", "go", "sure", "i", "im", "m", "apply", "save", "approve",
                 "complete", "anyway", "and", "all", "step", "alright", "understood", "start", "begin", "enter",
                 "return", "yep", "fine", "ready", "let", "s", "lets", "y"}
DELETE_PATH = re.compile(r"(?i)/(delete|remove|destroy|cancel|close|deactivate|unsubscribe|trash|erase)\w*(?:/|$)")


def neutral_button(label):
    """True for a label like OK, Continue, Done, Yes or "Confirm and continue", which names no action."""
    tokens = re.findall(r"[^\W\d_]+", str(label or "").lower().replace("\u2019", "").replace("'", ""))
    return bool(tokens) and len(tokens) <= 5 and set(tokens) <= NEUTRAL_WORDS


def context_kind(text):
    """The kind the words around a button name, by the same words a button would use. ("kind", "the line")."""
    for line in re.split(r"[\n\r]+|(?<=[.?!])\s+", str(text or "")):
        tokens = set(re.findall(r"[^\W\d_]+", line.lower()))
        if tokens & {"cookie", "cookies"}:
            tokens -= {"share", "sharing", "shared"}  # A cookie notice's "we share data with partners".
        if tokens & ENDERS and tokens & ENDED:
            return "delete", line
        for kind in PRIORITY:
            if tokens & BUTTON_WORDS[kind] or (kind == "buy" and tokens & {"order", "total", "card", "checkout"}):
                return kind, line
    return None, None


def page_kind(page):
    """Where the page's own form sends a press: (kind, address), read from its action and method, never its words."""
    if not isinstance(page, dict):
        return None, None
    found = []
    for form in page.get("forms") or []:
        if not isinstance(form, dict):
            continue
        method = str(form.get("formmethod") or form.get("method") or "get").upper()
        url = str(form.get("formaction") or form.get("action") or page.get("url") or "")
        host = _host(url)
        try:
            path = urlsplit(url).path or "/"
        except ValueError:
            path = "/"
        if method in ("GET", "HEAD", "DIALOG"):
            continue  # A form that only fetches a page.
        if method == "DELETE" or DELETE_PATH.search(path):
            found.append(("delete", url))
        elif any(host == h or host.endswith("." + h) for h in PAY_HOSTS) or PAY_PATH.search(path):
            found.append(("buy", url))
        elif POST_PATH.search(path):
            found.append(("post", url))
        elif SEND_PATH.search(path):
            found.append(("send", url))
    kind = _stronger(*(k for k, _ in found))
    return (kind, next(u for k, u in found if k == kind)) if kind else (None, None)


def _page_of(screen, tool, args):
    reader = getattr(screen, "page", None)
    if reader is None:
        return None
    try:
        return reader(tool, args)
    except Exception:
        return UNREADABLE


def _unsaid_press(label, tool, args, where, screen):
    """A labelled button that names no action. Its page's own form decides when Nollie can read it; a button
    that only says OK or Continue is judged by the window around it, and asks when that can't be read."""
    button = _button(label)
    headline = f"Press \u201c{button}\u201d on {where}."
    page = _page_of(screen, tool, args)
    kind, address = page_kind(page)
    if kind:
        return Action(kind, _summary(headline, [f"The page sends it to {_value(address, 160)}."]), button)
    if not neutral_button(label):
        return None
    if isinstance(page, dict) and PAY_PATH.search(urlsplit(str(page.get("url") or "")).path or ""):
        return Action("buy", _summary(headline, ["The page is a checkout."]), button)
    reader = getattr(screen, "around", None) or screen.text
    try:
        around = reader(tool, args)
    except Exception:
        around = UNREADABLE
    if around is UNREADABLE or around is None:
        return Action(UNSURE, _summary(headline, ["Nollie couldn't read what it's for, so it asks first."]), button)
    kind, line = context_kind(around)
    if kind:
        return Action(kind, _summary(headline, [f"Next to it: \u201c{_value(_one_line(line), 120)}\u201d"]), button)
    return None


class NoScreen:
    """Used where no screen can be read: every click and Return there asks first."""

    def label_at(self, tool, args):
        return UNREADABLE

    def text(self, tool, args):
        return UNREADABLE


# Files ------------------------------------------------------------------------------------------

def _temp_folders():
    found = set()
    for folder in (tempfile.gettempdir(), "/tmp", "/private/tmp", os.environ.get("TMPDIR")):
        if folder:
            try:
                found.add(os.path.realpath(folder))
            except (OSError, ValueError):
                pass
    return found


def _inside(path, folders):
    return any(path == folder or path.startswith(folder.rstrip("/") + "/") for folder in folders if folder)


class Files:
    """Whether writing to a path would replace a file that was already there before this turn.

    Files the bot made itself in this turn, and anything in its own scratch folder or the computer's
    temporary folders, can be written again freely. Every other file that exists counts, and a path that
    can't be checked is reported as None so the rule asks. ``new_turn`` is Hermes's ``pre_llm_call``.
    """

    def __init__(self, scratch=(), resolve=None, temporary=True):
        self.scratch = scratch
        self.resolve = resolve
        self.temporary = temporary
        self.lock = threading.Lock()
        self.made = {}

    def bind(self, task_id=None, session_id=None):
        return _BoundFiles(self, task_id, session_id)

    def new_turn(self, session_id=None, **_):
        with self.lock:
            self.made.pop(session_id or "", None)
        return None

    def replaces(self, path, cwd=None):
        return self.bind().replaces(path, cwd)

    def folder(self, path, cwd=None):
        return self.bind().folder(path, cwd)

    def _scratch(self):
        temporary = _temp_folders() if self.temporary else set()
        try:
            folders = self.scratch() if callable(self.scratch) else self.scratch
            return {os.path.realpath(str(f)) for f in folders or () if f} | temporary
        except Exception:
            return temporary


class _BoundFiles:
    def __init__(self, files, task_id, session_id):
        self.files, self.task_id, self.session = files, task_id, session_id or ""
        self.pending = []

    def _target(self, path, cwd):
        if self.files.resolve is not None:
            found = self.files.resolve(path, cwd, self.task_id)
            return None if found is None else os.path.realpath(str(found))
        candidate = Path(os.path.expanduser(path))
        if not candidate.is_absolute():
            candidate = Path(os.path.expanduser(cwd) if cwd else os.getcwd()) / candidate
        return os.path.realpath(str(candidate))

    def replaces(self, path, cwd=None):
        """True: a file that was there before is replaced or removed. False: a new file, one made this turn, or
        scratch. None: it can't be checked."""
        if not isinstance(path, str) or not path.strip() or "\x00" in path:
            return None
        try:
            target = self._target(path.strip(), cwd)
            if target is None:
                return None
            if _inside(target, self.files._scratch()):
                return False
            if not os.path.lexists(target):
                self.pending.append(target)
                return False
            if os.path.isdir(target):
                return False
        except (OSError, ValueError, RuntimeError):
            return None
        with self.files.lock:
            return target not in self.files.made.get(self.session, set())

    def folder(self, path, cwd=None):
        try:
            target = self._target(path, cwd) if isinstance(path, str) and path.strip() else None
            return bool(target) and os.path.isdir(target)
        except (OSError, ValueError, RuntimeError):
            return False

    def commit(self):
        """The call went ahead: the files it makes are the bot's own for the rest of the turn."""
        if not self.pending:
            return
        with self.files.lock:
            made = self.files.made.setdefault(self.session, set())
            made.update(self.pending)
            while len(self.files.made) > 256:
                self.files.made.pop(next(iter(self.files.made)))
        self.pending = []


FILE_WRITERS = frozenset(("write_file",))
OTHER_FILE_WRITERS = frozenset(("write_file", "create_file", "save_file", "overwrite_file", "put_file",
                                "write_text_file"))
PATH_KEYS = ("path", "file_path", "filepath", "filename", "file", "target", "destination")


def _replaced(path):
    return Action("delete", _summary(f"Replace {_value(path, 300)}, which was already there.",
                                     ["What it held before will be gone."]))


def _unchecked(path):
    return Action(UNSURE, _summary(f"Write to {_value(path, 300)}.",
                                   ["Nollie couldn't check whether a file is there already, so it asks first."]))


def file_write_found(path, files, cwd=None):
    """write_file and friends: asks before a file that was there already is replaced."""
    if not isinstance(path, str) or not path.strip():
        return None
    replaced = files.replaces(path, cwd)
    if replaced:
        return _replaced(path)
    if replaced is None:
        return _unchecked(path)
    return None


_PATCH_TARGET = re.compile(r"^\*\*\* (Add File|Move to|Move File):\s*(.+?)\s*$", re.M)


def patch_found(args, files):
    """A patch that adds a file where one is already, or moves a file onto one, replaces it."""
    text = "\n".join(str(v) for v in args.values() if isinstance(v, str))
    for match in _PATCH_TARGET.finditer(text):
        target = match.group(2)
        if match.group(1) == "Move File" and "->" in target:
            target = target.split("->", 1)[1].strip()
        replaced = files.replaces(target, args.get("workdir"))
        if replaced:
            return _replaced(target)
        if replaced is None:
            return _unchecked(target)
    return None


_REDIRECT = re.compile(r"^(\d*|&)?>\|?(?!>|&)(.*)$")


def overwrites_found(parts, cwd, files):
    """A shell command that writes over a file: ``>``, ``tee`` without -a, and cp, mv or install onto one."""
    if files is None or not parts:
        return None
    targets = []
    index = 1
    while index < len(parts):
        part = parts[index]
        match = _REDIRECT.match(part) if not part.startswith(">>") else None
        if match and not part.startswith(("<", "2>&", ">&")):
            target = match.group(2) or (parts[index + 1] if index + 1 < len(parts) else "")
            if target and not target.startswith("&") and target not in ("/dev/null", "/dev/stdout", "/dev/stderr",
                                                                         "/dev/tty"):
                targets.append(target)
            index += 1 if match.group(2) else 2
            continue
        index += 1
    program = _plain_program(parts[0])
    plain = [p for p in parts[1:] if not p.startswith("-") and not _REDIRECT.match(p) and p != ">"]
    flags = {p for p in parts[1:] if p.startswith("-")}
    if program == "tee" and not flags & {"-a", "--append"}:
        targets.extend(p for p in plain if p not in ("/dev/null",))
    if program in ("cp", "mv", "install", "ditto") and len(plain) >= 2 and not flags & {
            "-n", "--no-clobber", "--update=none"} and not any(re.match(r"^-[a-zA-Z]*n", f) for f in flags):
        destination, sources = plain[-1], plain[:-1]
        if "-t" in flags or "--target-directory" in flags:
            destination, sources = plain[0], plain[1:]
        if files.folder(destination, cwd):
            targets.extend(os.path.join(destination, os.path.basename(s.rstrip("/"))) for s in sources)
        else:
            targets.append(destination)
    for target in targets:
        if SUB in target or target.startswith("$"):
            return Found(UNSURE, "it writes to a file chosen when it runs")
        replaced = files.replaces(target, cwd)
        if replaced:
            return Found("delete", f"it writes over {target}, which was already there")
        if replaced is None:
            return Found(UNSURE, f"Nollie couldn't check whether {target} is there already")
    return None


# The rules --------------------------------------------------------------------------------------

def _read_script(path, cwd):
    try:
        candidate = Path(os.path.expanduser(path))
        if not candidate.is_absolute():
            candidate = Path(cwd or os.getcwd()) / candidate
        if not candidate.is_file() or candidate.stat().st_size > SCRIPT_LIMIT:
            return None
        return candidate.read_text(errors="replace")
    except (OSError, ValueError):
        return None


def _last(tool):
    parts = str(tool).split("__")
    return parts[-1].lower().replace("-", "_") if len(parts) >= 3 else str(tool).lower()


def classify(tool, args, *, screen=None, read_file=_read_script, describe=None, files=None):
    """The action this call takes that needs the person's yes, or None. Pure apart from ``screen``
    (which reads a computer's screen), ``read_file`` (which reads a script about to run), ``describe``
    (what another server's tool said it does when it was registered) and ``files`` (whether a file
    being written was there already)."""
    files = files if files is not None else Files()
    token = FILES.set(files)
    try:
        return _classify(tool, args, screen, read_file, describe, files)
    finally:
        FILES.reset(token)


def _described(describe, tool):
    if describe is None:
        return None
    try:
        info = describe(tool)
    except Exception:
        return None
    return info if isinstance(info, dict) else None


def _classify(tool, args, screen, read_file, describe, files):
    tool = str(tool or "")
    args = args if isinstance(args, dict) else ({} if args is None else {"value": args})
    calls = _inner_calls(tool, args)
    if calls is None and tool in ("tool_call", "connectors__execute"):
        return Action(UNSURE, _summary(f"Use {tool}.", ["Nollie couldn't read which tools it calls, so it asks."]))
    if calls and tool in ("tool_call", "connectors__execute") and all(t.startswith("connectors__") for t, _ in calls):
        # Hermes runs this hook again for each connector call in the batch: asking here would ask twice.
        return None
    if calls:
        found = [a for a in (_classify(t, a, screen, read_file, describe, files) for t, a in calls) if a]
        if not found:
            if tool in ("tool_call", "connectors__execute"):
                return None
        elif len(found) == 1:
            return found[0]
        else:
            kind = _stronger(*(a.kind for a in found))
            has_command = any(a.has_command for a in found)
            return Action(kind, _summary(f"{len(found)} actions at once:", [a.summary for a in found],
                                          limit=None if has_command else SUMMARY_LIMIT),
                          next((a.button for a in found if a.button), None), has_command=has_command)
    if tool in EXEMPT or tool in LOOKS or tool in APPLE_DATA or tool in PAYMENTS:
        return None
    screen = screen or NoScreen()
    last = _last(tool)

    if tool in SHELL_TOOLS:
        command = args.get("command") or args.get("cmd") or args.get("script")
        if tool != "terminal" and str(args.get("action") or "").lower() in ("write", "submit", "send", "send_keys"):
            command = args.get("data") or args.get("input") or args.get("text")
            if isinstance(command, str) and command.strip():
                found = shell_found(command, read_file=read_file) or code_found(command)
                if found:
                    return Action(found.kind, _summary("Type this into a running program:",
                                                       [command, f"Why Nollie asks: {found.why}."], limit=None),
                                  has_command=True)
            return None
        if not isinstance(command, str) or not command.strip():
            return None
        found = shell_found(command, cwd=args.get("workdir") or args.get("cwd"), read_file=read_file)
        if not found:
            return None
        return Action(found.kind, _summary("Run this command:", [command, f"Why Nollie asks: {found.why}."],
                                            limit=None), has_command=True)
    if tool in CODE_TOOLS:
        code = args.get("code") or args.get("source")
        found = code_found(code, str(args.get("language") or "py")[:2].lower())
        if not found:
            return None
        return Action(found.kind, _summary("Run this code:", [_value(code, 1200), f"Why Nollie asks: {found.why}."]))
    if tool == "patch":
        text = json.dumps(args, ensure_ascii=False)
        if re.search(r"\*\*\* Delete File:", text) or str(args.get("mode", "")).lower() == "delete" or \
                re.search(r"\*\*\* Move File:[^\n]*->\s*[^\n]*(\.Trash|/dev/null)", text):
            return Action("delete", _summary("Delete a file with a patch:", detail_lines(args)))
        return patch_found(args, files)
    if tool in FILE_WRITERS:
        return file_write_found(args.get("path"), files, args.get("workdir"))
    if other_server(tool) and _last(tool) in OTHER_FILE_WRITERS:
        path = next((args[k] for k in PATH_KEYS if isinstance(args.get(k), str)), None)
        if path and files.replaces(path) is True:
            return _replaced(path)
    if tool.startswith("mcp__nollie_mac__"):
        return None  # Nollie Computer asks on the Mac itself, with the label it reads there.

    # Computers and pages: Hermes's own, Cua's, and any other server's click, key, type and script tools.
    computer = tool == "computer_use" or tool.startswith(("browser_", "mcp__cua")) or last in (
        CLICKS | KEYS | TYPES | DIALOGS | SCRIPTS | PRESSES) or last.startswith(("browser_", "computer_"))
    if computer:
        short = last
        if tool == "computer_use":
            action = str(args.get("action") or "").strip().lower()
            short = {"key": "key", "type": "type", "set_value": "set_value"}.get(action, action)
        where = _computer_name(tool, args, include_id=short not in CLICKS | KEYS | TYPES | PRESSES)
        if short in ("computer_shell", "space_bash", "shell", "bash", "run_command", "computer_run"):
            command = args.get("command") or args.get("cmd")
            found = shell_found(command, read_file=None) if isinstance(command, str) else None
            if found:
                return Action(found.kind, _summary(f"Run this command on {where}:",
                                                   [command, f"Why Nollie asks: {found.why}."], limit=None),
                              has_command=True)
            return None
        if "task" in short and tool.startswith("mcp__cua"):
            task = " ".join(str(args.get(k) or "") for k in ("task", "instructions", "prompt", "goal"))
            kind = kind_of(words(task), lead=False)
            return Action(kind or UNSURE, _summary(f"Hand a whole task to {where}:", [_value(task, 800),
                                                   "Nollie can't see each step it takes, so it asks first."]))
        found = computer_action(short, tool, args, where, screen)
        if found or short in CLICKS | KEYS | TYPES | DIALOGS | SCRIPTS | PRESSES:
            return found
        if tool.startswith("mcp__cua__") and not short.startswith("computer_"):
            kind = kind_of(words(short))
            return Action(kind, _summary(f"{LEADS[kind]} with Cua ({short}):", detail_lines(args))) if kind else None
        if tool == "computer_use" or tool.startswith("browser_") or tool.startswith("mcp__cua"):
            return None

    server, name = _tool_words(tool)
    tokens = words(name)
    kind = kind_of(tokens)
    for key in ACTION_KEYS:
        value = args.get(key)
        if isinstance(value, str) and value.strip() and len(value) <= 80:
            kind = _stronger(kind, kind_of(words(value), lead=key in ("action", "operation", "op", "action_name",
                                                                      "function")))
    for item in args.get("operations") or [] if isinstance(args.get("operations"), list) else []:
        if isinstance(item, dict):
            for key in ACTION_KEYS:
                if isinstance(item.get(key), str):
                    kind = _stronger(kind, kind_of(words(item[key])))
    method = str(args.get("method") or args.get("http_method") or args.get("httpMethod") or "")
    url = next((v for k, v in args.items() if isinstance(v, str) and (k in ("url", "endpoint", "uri", "path", "route")
                                                                       or k.lower().endswith("url"))), "")
    if method.upper() in ("POST", "PUT", "PATCH", "DELETE"):
        kind = _stronger(kind, _url_kind(url, method.upper()))
    elif method and not method.upper() in ("GET", "HEAD", "OPTIONS"):
        kind = _stronger(kind, kind_of(words(method)))
    if set(tokens) & {"webhook", "hook"} and (set(tokens) & MAKERS or url):
        kind = _stronger(kind, "send")
    if set(tokens) & {"workflow", "zap", "automation", "flow", "scenario", "recipe", "agent", "task"} and \
            set(tokens) & {"run", "execute", "trigger", "start", "invoke", "fire", "perform", "do"} and \
            not _plainly_reads(tokens):
        task = " ".join(str(v) for k, v in args.items() if isinstance(v, str))
        kind = _stronger(kind, kind_of(words(task), lead=False) or UNSURE)
    found = _args_found(tokens, args)
    if found:
        kind = _stronger(kind, found.kind)
    for key in ("command", "cmd", "script"):
        if isinstance(args.get(key), str) and args[key].strip():
            found = shell_found(args[key], read_file=None)
            if found:
                kind = _stronger(kind, found.kind)
    for key in ("code", "source"):
        if isinstance(args.get(key), str) and set(tokens) & {"code", "exec", "execute", "run", "eval", "python",
                                                            "javascript", "js", "script", "notebook", "cell"}:
            found = code_found(args[key])
            if found:
                kind = _stronger(kind, found.kind)
    why = None
    if not kind and other_server(tool):
        found = other_server_found(tool, tokens, args, _described(describe, tool))
        if found:
            kind, why = found.kind, f"Why Nollie asks: {found.why}."
    if not kind:
        return None
    where_words = f" with {server}" if server else ""
    first = f"{LEADS[kind]}{where_words}: {' '.join(tokens) or name}"
    return Action(kind, _summary(first, ([why] if why else []) + detail_lines(args)))


# The hook ---------------------------------------------------------------------------------------

def rule_key(action, new_id=None):
    """A fresh key per call, so a Session or Always answer can never cover a later action."""
    return f"{RULE_PREFIX}{action.kind}:{(new_id or (lambda: uuid.uuid4().hex))()}"


class AskFirst:
    """The ``pre_tool_call`` hook. Hermes pieces are injected so tests can stand in for them.

    ``unsure`` is the bot's Ask first switch: off, the calls Nollie can't read (kind ``unsure``) run without a
    card. Whatever it says, a call the rules name as sending, buying, posting or deleting always asks.
    """

    def __init__(self, *, unattended, bypassed, screen=None, read_file=_read_script, new_id=None, redactor=None,
                 describe=None, files=None, unsure=None):
        self.unattended = unattended
        self.bypassed = bypassed
        self.screen = screen
        self.read_file = read_file
        self.new_id = new_id or (lambda: uuid.uuid4().hex)
        self.redactor = redactor
        self.describe = describe
        self.files = files if files is not None else Files()
        self.unsure = unsure or (lambda: True)

    def _asks_when_unsure(self):
        try:
            return self.unsure() is not False
        except Exception:
            return True

    def action(self, tool_name, args, task_id=None, session_id=None):
        """(the action, whether the rules could read the call)."""
        screen, files = self.screen, self.files
        if screen is not None and hasattr(screen, "bind"):
            screen = screen.bind(task_id, session_id)
        if hasattr(files, "bind"):
            files = files.bind(task_id, session_id)
        try:
            found = classify(tool_name, args, screen=screen, read_file=self.read_file, describe=self.describe,
                             files=files)
        except Exception:
            # Fails closed: a call the rules choke on asks rather than slipping through, switch or no switch.
            return Action(UNSURE, _summary(f"Use {tool_name}.", ["Nollie couldn't read this action, so it asks."])), \
                False
        if found is None and hasattr(files, "commit"):
            files.commit()
        return found, True

    def _safe(self, text):
        if self.redactor is None:
            return text
        try:
            cleaned = self.redactor(text)
            return cleaned if isinstance(cleaned, str) else "[hidden]"
        except Exception:
            return "[hidden]"

    def hook(self, tool_name=None, args=None, task_id=None, session_id=None, **_):
        found, read = self.action(tool_name, args, task_id, session_id)
        if found is None:
            return None
        if read and found.kind == UNSURE and not self._asks_when_unsure():
            return None
        summary = plain_lines(self._safe(found.summary))
        try:
            nobody = bool(self.unattended())
        except Exception:
            nobody = True
        if nobody:
            return {"action": "block", "message": HELD_MESSAGE.format(summary=summary)}
        try:
            off = bool(self.bypassed(session_id))
        except Exception:
            off = True
        if off:
            return {"action": "block", "message": BYPASSED_MESSAGE.format(summary=summary)}
        safe = Action(found.kind, summary, found.button, has_command=found.has_command)
        return {"action": "approve", "message": safe.description(), "rule_key": rule_key(found, self.new_id)}


# Hermes glue ------------------------------------------------------------------------------------

def hermes_unattended(ctx):
    """True for a schedule, a Board task, a single-query run or any run nobody can answer. Doubt counts."""
    def check():
        try:
            if ctx.current_cron_execution() is not None:
                return True
        except Exception:
            pass
        if os.environ.get("HERMES_KANBAN_TASK"):
            return True
        from gateway.session_context import get_session_env
        if str(get_session_env("HERMES_CRON_SESSION", "") or "").strip().lower() in ("1", "true", "yes"):
            return True
        from tools.approval_context import _is_cron_approval_context, _no_user_can_answer
        return bool(_is_cron_approval_context() or _no_user_can_answer())
    return check


def hermes_bypassed(session_id=None):
    """True when Hermes would approve without asking anyone: YOLO, or approvals switched off."""
    from tools import approval
    if approval.is_approval_bypass_active():
        return True
    return bool(session_id) and bool(approval.is_approval_bypass_active_for_session(str(session_id)))


SWITCH_FILE = "ask-first.json"


class Switch:
    """The bot's Ask first switch, ``<bot home>/nollie-workflow/ask-first.json``, read again when it changes.

    Only ``{"version": 1, "enabled": false}`` turns it off. A missing, linked or damaged file leaves it on."""

    def __init__(self, home):
        self.path = Path(home) / "nollie-workflow" / SWITCH_FILE
        self._seen = None

    def __call__(self):
        try:
            info = os.lstat(self.path)
        except FileNotFoundError:
            return True
        except OSError:
            return True
        signature = (info.st_mtime_ns, info.st_size, info.st_ino, info.st_mode)
        if self._seen is None or self._seen[0] != signature:
            on = True
            try:
                if not os.path.islink(self.path) and info.st_size <= 4096:
                    document = json.loads(self.path.read_text())
                    on = not (isinstance(document, dict) and document.get("version") == 1
                              and document.get("enabled") is False)
            except (OSError, ValueError, UnicodeDecodeError):
                on = True
            self._seen = (signature, on)
        return self._seen[1]


def hermes_describe(tool):
    """What another server's tool said about itself when Hermes registered it: description, fields, server."""
    if not str(tool).startswith(("mcp__", "connectors__")):
        return None
    from tools.registry import registry
    entry = registry.get_entry(str(tool))
    if entry is None:
        return None
    schema = entry.schema if isinstance(entry.schema, dict) else {}
    return {"description": schema.get("description") or entry.description or "",
            "parameters": schema.get("parameters") if isinstance(schema.get("parameters"), dict) else {},
            "server": str(entry.toolset or "").removeprefix("mcp-")}


def hermes_files(bot_home):
    """The files checker for a bot: Hermes resolves a path the way its file tools will, and the bot's own
    scratch folder (``<home>/cache/scratch``) is its own."""
    def resolve(path, cwd, task_id):
        from tools.file_tools_paths import _resolve_path_for_task, _terminal_env_type_for_task
        if _terminal_env_type_for_task(task_id or "default") != "local":
            return None  # Files in a container or on another computer can't be checked from here.
        if cwd:
            candidate = Path(os.path.expanduser(path))
            return candidate if candidate.is_absolute() else Path(os.path.expanduser(cwd)) / candidate
        return _resolve_path_for_task(path, task_id or "default")
    return Files(scratch=lambda: [Path(bot_home) / "cache" / "scratch"], resolve=resolve)

