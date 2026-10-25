"""What a site says about being read: robots.txt (RFC 9309), ai.txt, Content-Signal,
X-Robots-Tag and robots meta tags. Parsing only; no network here."""
from __future__ import annotations

from dataclasses import dataclass, field
import re
from urllib.parse import unquote

MAX_RULES_BYTES = 500 * 1024
_LINE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$")


def _normalise_path(path):
    # Compare percent-decoded forms so /caf%C3%A9 and /café match the same rule.
    try:
        return unquote(path or "/", errors="strict")
    except UnicodeDecodeError:
        return path or "/"


def _pattern_regex(pattern):
    anchored = pattern.endswith("$")
    body = pattern[:-1] if anchored else pattern
    regex = ".*".join(re.escape(piece) for piece in _normalise_path(body).split("*"))
    return re.compile(regex + ("$" if anchored else ""), re.DOTALL)


@dataclass
class Group:
    agents: list = field(default_factory=list)
    rules: list = field(default_factory=list)  # (allow, pattern, compiled)
    crawl_delay: float | None = None
    signals: dict = field(default_factory=dict)


@dataclass
class RulesFile:
    groups: list = field(default_factory=list)
    signals: dict = field(default_factory=dict)  # Content-Signal outside any group
    allow_all: bool = False
    disallow_all: bool = False

    @classmethod
    def allowing(cls):
        return cls(allow_all=True)

    @classmethod
    def refusing(cls):
        return cls(disallow_all=True)

    def _groups_for(self, token):
        token = token.lower()
        named = [g for g in self.groups if token in g.agents]
        return named or [g for g in self.groups if "*" in g.agents]

    def allowed(self, token, path):
        if self.allow_all:
            return True
        if self.disallow_all:
            return False
        if path == "/robots.txt":
            return True
        target = _normalise_path(path)
        best = None  # (length, allow)
        for group in self._groups_for(token):
            for allow, pattern, compiled in group.rules:
                if compiled.match(target):
                    candidate = (len(pattern), allow)
                    if best is None or candidate[0] > best[0] or (candidate[0] == best[0] and allow):
                        best = candidate
        return True if best is None else best[1]

    def crawl_delay(self, token):
        delays = [g.crawl_delay for g in self._groups_for(token) if g.crawl_delay is not None]
        return max(delays) if delays else None

    def content_signals(self, token):
        merged = dict(self.signals)
        for group in self._groups_for(token):
            merged.update(group.signals)
        return merged


def parse_signals(value):
    """``Content-Signal: search=yes, ai-input=no`` into {"search": True, "ai-input": False}."""
    out = {}
    for part in value.split(","):
        key, _, setting = part.strip().partition("=")
        setting = setting.strip().lower()
        if key and setting in ("yes", "y", "no", "n"):
            out[key.strip().lower()] = setting in ("yes", "y")
    return out


def parse(text):
    """RFC 9309 groups: consecutive user-agent lines open a group; rules attach to it."""
    result = RulesFile()
    current = None
    taking_agents = False
    for raw in text.splitlines():
        line = raw.split("#", 1)[0]
        match = _LINE.match(line)
        if not match:
            continue
        key, value = match.group(1).lower().replace("_", "-"), match.group(2)
        if key == "user-agent":
            if not taking_agents:
                current = Group()
                result.groups.append(current)
                taking_agents = True
            current.agents.append(value.strip().lower())
            continue
        taking_agents = False
        if key == "content-signal":
            target = current.signals if current is not None else result.signals
            target.update(parse_signals(value))
            continue
        if current is None:
            continue
        if key in ("allow", "disallow"):
            if not value:
                continue  # an empty Disallow allows everything
            if not value.startswith(("/", "*")):
                value = "*" + value if value.startswith(".") else "/" + value
            current.rules.append((key == "allow", value, _pattern_regex(value)))
        elif key == "crawl-delay":
            try:
                delay = float(value)
            except ValueError:
                continue
            if 0 <= delay < 86400:
                current.crawl_delay = delay
    return result


def looks_like_rules(text):
    return bool(re.search(r"(?im)^\s*user-agent\s*:", text or ""))


# ---- page-level signals -------------------------------------------------------------------

AI_REFUSALS = ("noai",)
_AGENT_PREFIX = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_.-]*)\s*:\s*(.*)$")
_KNOWN_DIRECTIVES = frozenset({
    "all", "noindex", "nofollow", "none", "noarchive", "nosnippet", "noimageindex", "notranslate",
    "noai", "noimageai", "nocache", "indexifembedded", "max-snippet", "max-image-preview",
    "max-video-preview", "unavailable_after",
})


def _directives(value):
    return {d.strip().lower() for d in value.split(",") if d.strip()}


def header_directives(values, token):
    """X-Robots-Tag values that apply to ``token`` (unscoped ones apply to everyone)."""
    found = set()
    for value in values:
        match = _AGENT_PREFIX.match(value)
        if match and match.group(1).lower() not in _KNOWN_DIRECTIVES:
            if match.group(1).lower() in (token.lower(), "*"):
                found |= _directives(match.group(2))
            continue
        found |= _directives(value)
    return found


def meta_directives(metas, token):
    """``metas`` is a list of (name, content) pairs from the page head."""
    found = set()
    for name, content in metas:
        if (name or "").strip().lower() in ("robots", token.lower()):
            found |= _directives(content or "")
    return found


@dataclass
class PageSignals:
    refuse_ai: bool = False
    no_images: bool = False
    no_archive: bool = False

    @classmethod
    def from_directives(cls, directives):
        return cls(
            refuse_ai="noai" in directives,
            no_images="noimageai" in directives or "noai" in directives,
            no_archive=bool({"noarchive", "nocache"} & directives),
        )
