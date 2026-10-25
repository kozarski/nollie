"""Turn fetched bytes into clean text.

HTML goes to Trafilatura and PDFs to pypdf when the add-on's own environment has them; that
work runs in a separate helper process so the libraries never load into Hermes. Without the
helper, HTML uses the careful standard-library reader below and PDFs are declined honestly.
"""
from __future__ import annotations

from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess

HELPER = Path(__file__).with_name("extract_helper.py")

_SKIP = frozenset({"script", "style", "noscript", "template", "svg", "canvas", "iframe", "object",
                   "embed", "button", "select", "textarea", "nav", "aside", "footer", "dialog",
                   "math", "audio", "video", "picture", "map"})
_VOID = frozenset({"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                   "param", "source", "track", "wbr"})
_BLOCK = frozenset({"p", "div", "section", "article", "main", "header", "li", "ul", "ol", "dl", "dt", "dd",
                    "blockquote", "pre", "table", "tr", "figure", "figcaption", "h1", "h2", "h3", "h4",
                    "h5", "h6", "hr", "br", "address", "details", "summary", "caption", "tbody", "thead"})
_SKIP_ROLES = frozenset({"navigation", "banner", "contentinfo", "complementary", "search", "dialog",
                         "alertdialog", "menu", "menubar"})
_NOISE = re.compile(r"(?:^|[\s_-])(cookie|consent|gdpr|newsletter|subscribe|share|sharing|social|related|"
                    r"comments?|advert|ads?|promo|sponsor|sidebar|breadcrumbs?|menu|popup|modal|paywall|"
                    r"signup|sign-up|skip-link|visually-hidden|sr-only)(?:$|[\s_-])", re.I)


class _Page(HTMLParser):
    def __init__(self, markdown):
        super().__init__(convert_charrefs=True)
        self.markdown = markdown
        self.stack = []  # (tag, skipping, main)
        self.blocks = []  # (in_main, text)
        self.line = []
        self.title = ""
        self.og_title = ""
        self.metas = []
        self.charset = ""
        self._in_title = False
        self._pre = 0
        self._prefix = ""
        self.has_main = False

    # state helpers
    def _skipping(self):
        return bool(self.stack) and self.stack[-1][1]

    def _in_main(self):
        return bool(self.stack) and self.stack[-1][2]

    def _flush(self):
        text = "".join(self.line)
        self.line = []
        if not self._pre:
            text = re.sub(r"\s+", " ", text).strip()
        if text:
            self.blocks.append((self._in_main(), self._prefix + text))
        self._prefix = ""

    def handle_starttag(self, tag, attrs):
        attrs = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            name = attrs.get("name") or attrs.get("property") or attrs.get("http-equiv")
            if name:
                self.metas.append((name.lower(), attrs.get("content", "")))
                if name.lower() == "og:title":
                    self.og_title = attrs.get("content", "").strip()
                if name.lower() == "content-type" and "charset=" in attrs.get("content", "").lower():
                    self.charset = attrs["content"].lower().split("charset=")[-1].strip(" ;\"'")
            if attrs.get("charset"):
                self.charset = attrs["charset"].strip().lower()
            return
        if tag == "title":
            self._in_title = True
            return
        if tag in _VOID:
            if tag in ("br", "hr") and not self._skipping():
                self._flush()
            elif tag == "img" and not self._skipping() and self.markdown and attrs.get("alt", "").strip():
                self.line.append(f" [image: {attrs['alt'].strip()}] ")
            return
        parent_skip = self._skipping()
        parent_main = self._in_main()
        noise = " ".join((attrs.get("class", ""), attrs.get("id", "")))
        skip = (parent_skip or tag in _SKIP or attrs.get("role", "").lower() in _SKIP_ROLES
                or "hidden" in attrs or attrs.get("aria-hidden", "").lower() == "true"
                or (tag == "header" and not parent_main) or bool(_NOISE.search(noise)))
        main = parent_main or tag in ("main", "article") or attrs.get("role", "").lower() == "main"
        if main and not parent_main:
            self.has_main = True
        if tag in _BLOCK and not parent_skip:
            self._flush()
        self.stack.append((tag, skip, main))
        if skip:
            return
        if tag == "pre":
            self._pre += 1
        if self.markdown and tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._prefix = "#" * int(tag[1]) + " "
        elif tag == "li":
            self._prefix = "- "
        elif tag in ("td", "th") and self.line:
            self.line.append(" | ")

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
            return
        if tag in _VOID or not any(t == tag for t, _, _ in self.stack):
            return
        while self.stack:
            current, skip, _ = self.stack[-1]
            if current in _BLOCK and not skip:
                self._flush()
            if current == "pre" and not skip:
                self._pre = max(0, self._pre - 1)
            self.stack.pop()
            if current == tag:
                break

    def handle_data(self, data):
        if self._in_title:
            self.title += data
            return
        if not self._skipping():
            self.line.append(data)

    def finish(self):
        self.close()
        self._flush()
        keep = [text for in_main, text in self.blocks if in_main] if self.has_main else []
        if not keep:
            keep = [text for _, text in self.blocks]
        lines, previous = [], None
        for text in keep:
            if text != previous:
                lines.append(text)
            previous = text
        return "\n\n".join(lines)


def read_html_basic(html, markdown=True):
    """(title, text, metas). Keeps the main or article part when the page marks one."""
    page = _Page(markdown)
    try:
        page.feed(html)
        text = page.finish()
    except Exception:
        text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html)).strip()
    title = re.sub(r"\s+", " ", page.og_title or page.title).strip()
    return title, text, page.metas


def head_metas(html):
    page = _Page(False)
    try:
        page.feed(html[:400_000])
    except Exception:
        pass
    return page.metas, page.charset


def decode_html(body, content_type):
    charset = ""
    match = re.search(r"charset=([\w.:-]+)", content_type or "", re.I)
    if match:
        charset = match.group(1)
    if not charset:
        sniff = re.search(rb"<meta[^>]+charset=[\"']?([\w.:-]+)", body[:4096], re.I)
        if sniff:
            charset = sniff.group(1).decode("ascii", "ignore")
    for candidate in (charset, "utf-8"):
        if not candidate:
            continue
        try:
            return body.decode(candidate)
        except (LookupError, UnicodeDecodeError):
            continue
    return body.decode("utf-8", errors="replace")


class Helper:
    """Runs extract_helper.py in the add-on's own Python, if one is installed."""

    def __init__(self, python=None, timeout=45):
        self.python = python
        self.timeout = timeout
        self._capabilities = None

    @classmethod
    def find(cls, root):
        configured = os.environ.get("NOLLIE_READER_PYTHON", "").strip()
        candidate = Path(configured) if configured else Path(root) / "venv" / "bin" / "python"
        return cls(str(candidate) if candidate.is_file() else None)

    def _run(self, request):
        if not self.python:
            return None
        env = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
        try:
            done = subprocess.run([self.python, "-I", str(HELPER)], input=json.dumps(request).encode(),
                                  capture_output=True, timeout=self.timeout, env=env, check=False)
            reply = json.loads(done.stdout.decode("utf-8") or "{}")
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
        return reply if isinstance(reply, dict) else None

    def capabilities(self):
        if self._capabilities is None:
            reply = self._run({"kind": "ping"}) or {}
            self._capabilities = {"html": bool(reply.get("html")), "pdf": bool(reply.get("pdf"))}
        return self._capabilities

    def html(self, html, url, markdown):
        if not self.capabilities()["html"]:
            return None
        reply = self._run({"kind": "html", "html": html, "url": url, "markdown": markdown})
        if reply and reply.get("ok") and (reply.get("text") or "").strip():
            return reply.get("title") or "", reply["text"]
        return None

    def pdf(self, data_path):
        if not self.capabilities()["pdf"]:
            return None
        reply = self._run({"kind": "pdf", "path": str(data_path)})
        if reply and reply.get("ok"):
            return reply.get("title") or "", reply.get("text") or ""
        return None
