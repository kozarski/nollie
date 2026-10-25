"""Nollie's polite page reader.

For each page: a public address only (checked again after DNS and after every redirect), the
site's robots.txt and AI-use signals, a turn in the shared queue for that site, one plain
request with Nollie's own user agent and no cookies, then clean text. Sign-in walls, bot
blocks, slow-down replies and human checks come back as "This site wants a person" and are
never tried again through another service.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import os
from pathlib import Path
import tempfile
import time
from urllib.parse import urljoin

from . import extract, netsafe, rules
from .cache import Cache
from .limits import HostPacer, Resting, retry_after_seconds
from .state import ensure_dir, locked_json, read_json, shared_root

READER = "nollie-reader"
MAX_REDIRECTS = 5
MAX_HTML = 5_000_000
MAX_PDF = 25_000_000
MAX_TEXT_OUT = 1_000_000
RULES_TTL = 3600.0
RULES_RETRY_TTL = 600.0
HANDOFF_TTL = 3600.0

_ACCEPT = "text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.1"
_HTML_TYPES = ("text/html", "application/xhtml+xml")
_TEXT_TYPES = ("text/plain", "text/markdown", "text/csv", "application/json", "application/xml", "text/xml")
_PERSON = {
    401: "asks for a sign-in", 402: "asks for payment", 403: "turned automated readers away",
    407: "asks for a sign-in", 429: "asked automated readers to slow down",
    451: "is not available here for legal reasons",
}
_STRONG_CHALLENGE = (b"challenge-platform", b"cf-chl-", b"cf_chl_", b"challenges.cloudflare.com",
                     b"captcha-delivery.com", b"px-captcha", b"_incapsula_resource", b"g-recaptcha",
                     b"h-captcha", b"hcaptcha.com/1/api", b"aws-waf-token", b"sec-if-cpt", b"ddos-guard")
_WEAK_CHALLENGE = (b"just a moment...", b"attention required! | cloudflare", b"verify you are human",
                   b"are you a robot", b"checking your browser", b"please verify you are a human",
                   b"press &amp; hold", b"press & hold", b"captcha")

STOP = "Nollie stopped and will not try another tool or service for this page."
SHARE = "Share the link and ask a person to open it."


@dataclass
class Outcome:
    url: str
    title: str = ""
    text: str = ""
    error: str = ""
    refused: bool = False         # the site or Nollie's rules said no: never route around it
    wants_person: bool = False
    final_url: str = ""
    status: int = 0
    kind: str = ""
    cache: bool = True
    notes: list = field(default_factory=list)

    def as_result(self):
        meta = {"sourceURL": self.url, "reader": READER}
        if self.final_url:
            meta["finalURL"] = self.final_url
        if self.status:
            meta["status"] = self.status
        if self.kind:
            meta["kind"] = self.kind
        if self.notes:
            meta["notes"] = list(self.notes)
        if self.error:
            entry = {"url": self.url, "title": "", "content": "", "error": self.error, "metadata": meta}
            if self.refused:
                entry["blocked_by_policy"] = True
                meta["wants_person"] = self.wants_person
            return entry
        return {"url": self.url, "title": self.title, "content": self.text, "raw_content": self.text,
                "metadata": {**meta, "title": self.title}}

    def to_cache(self):
        return {k: getattr(self, k) for k in ("url", "title", "text", "error", "refused", "wants_person",
                                               "final_url", "status", "kind", "notes")}


def _refusal(url, message, *, person=False, status=0):
    return Outcome(url, error=message, refused=True, wants_person=person, status=status)


def _person(url, why, status):
    return _refusal(url, f"This site wants a person: it {why} (HTTP {status}). {STOP} {SHARE}",
                    person=True, status=status)


def _challenge(url, status):
    return _refusal(url, f"This site wants a person: it showed a human check instead of the page. {STOP} {SHARE}",
                    person=True, status=status)


def looks_like_challenge(response, text_length=None):
    if response.header("cf-mitigated").lower() == "challenge":
        return True
    body = response.body[:200_000].lower()
    strong = any(marker in body for marker in _STRONG_CHALLENGE)
    weak = any(marker in body for marker in _WEAK_CHALLENGE)
    if response.status in (403, 429, 503):
        return strong or weak
    # A normal page can mention CAPTCHAs. Only a short page carrying a challenge widget counts.
    short = text_length is not None and text_length < 1500
    return short and strong


class Reader:
    def __init__(self, root=None, *, resolver=netsafe.system_resolver, allowed=netsafe.address_allowed,
                 clock=time.time, sleep=time.sleep, host_interval=None, ttl=None, timeout=15.0,
                 deadline=90.0, helper=None, token=netsafe.AGENT_TOKEN):
        self.root = ensure_dir(Path(root) if root else shared_root())
        settings = read_json(self.root / "settings.json", {})
        self.resolver, self.allowed = resolver, allowed
        self.clock, self.sleep = clock, sleep
        self.timeout, self.deadline, self.token = timeout, deadline, token
        interval = host_interval if host_interval is not None else float(settings.get("host_interval", 2.0))
        self.pacer = HostPacer(self.root, clock=clock, sleep=sleep, interval=interval)
        self.cache = Cache(self.root, ttl=ttl if ttl is not None else float(settings.get("cache_ttl", 3600.0)),
                           clock=clock)
        self.helper = helper if helper is not None else extract.Helper.find(self.root)

    # ---- public ------------------------------------------------------------------------

    def read(self, url, format="markdown", *, deadline_at=None):
        deadline_at = deadline_at or (self.clock() + self.deadline)
        markdown = (format or "markdown") != "text"
        try:
            target = netsafe.normalize(url)
        except netsafe.Refused as refused:
            return _refusal(url, f"{refused.reason} Nollie stopped.").as_result()
        key = [target.url, markdown]
        cached = self.cache.get("page", key)
        if cached is not None:
            outcome = Outcome(**cached)
            outcome.url = url
            outcome.notes = list(outcome.notes) + ["from Nollie's one-hour cache"]
            return outcome.as_result()
        outcome = self._read(url, target, markdown, deadline_at)
        if outcome.wants_person:
            self._remember_handoff(outcome)
        if outcome.cache and (outcome.refused or not outcome.error):
            self.cache.put("page", key, outcome.to_cache())
        return outcome.as_result()

    def read_many(self, urls, format="markdown"):
        """Sites are read side by side; pages on the same site wait their turn."""
        deadline_at = self.clock() + self.deadline
        groups = {}
        for index, url in enumerate(urls):
            try:
                host = netsafe.normalize(url).host
            except netsafe.Refused:
                host = f"invalid-{index}"
            groups.setdefault(host, []).append((index, url))
        results = [None] * len(urls)

        def run(items):
            for index, url in items:
                try:
                    results[index] = self.read(url, format, deadline_at=deadline_at)
                except Exception as error:  # never let one page break the batch
                    results[index] = Outcome(url, error=f"Nollie could not read this page ({type(error).__name__}).").as_result()

        with ThreadPoolExecutor(max_workers=min(4, max(1, len(groups)))) as pool:
            list(pool.map(run, groups.values()))
        return results

    # ---- internals ---------------------------------------------------------------------

    def _remaining(self, deadline_at):
        return max(0.0, deadline_at - self.clock())

    def _request(self, target, deadline_at, *, crawl_delay=None, max_bytes=MAX_HTML, accept=_ACCEPT):
        remaining = self._remaining(deadline_at)
        if remaining <= 1:
            raise TimeoutError()
        self.pacer.wait_turn(target.host, crawl_delay=crawl_delay, max_wait=min(20.0, remaining - 1))
        return netsafe.fetch_once(target, headers={"Accept": accept, "Accept-Language": "en;q=1.0, *;q=0.5"},
                                  timeout=min(self.timeout, max(1.0, self._remaining(deadline_at))),
                                  max_bytes=max_bytes, resolver=self.resolver, allowed=self.allowed,
                                  total_timeout=max(1.0, min(60.0, self._remaining(deadline_at))))

    def _rules_for(self, target, deadline_at):
        """robots.txt and ai.txt for this origin, cached for an hour (ten minutes after a failure)."""
        cached = self.cache.get("rules", target.origin)
        if cached is None:
            robots = self._fetch_rules(target, "/robots.txt", deadline_at)
            ai = (self._fetch_rules(target, "/ai.txt", deadline_at) if robots["state"] != "unreachable"
                  else {"state": "none", "text": ""})
            cached = {"robots": robots, "ai": ai}
            ttl = RULES_RETRY_TTL if cached["robots"]["state"] == "unreachable" else RULES_TTL
            self.cache.put("rules", target.origin, cached, ttl=ttl)
        robots = cached["robots"]
        if robots["state"] == "ok":
            robots_rules = rules.parse(robots["text"])
        elif robots["state"] == "none":
            robots_rules = rules.RulesFile.allowing()
        else:
            robots_rules = None
        ai = cached["ai"]
        ai_rules = rules.parse(ai["text"]) if ai["state"] == "ok" and rules.looks_like_rules(ai["text"]) else None
        return robots_rules, ai_rules

    def _fetch_rules(self, target, path, deadline_at):
        url = target.origin + path
        for _ in range(MAX_REDIRECTS + 1):
            try:
                hop = netsafe.normalize(url)
                response = self._request(hop, deadline_at, max_bytes=rules.MAX_RULES_BYTES, accept="text/plain,*/*;q=0.5")
            except (Resting, netsafe.Refused):
                raise
            except (LookupError, ConnectionError, TimeoutError, OSError):
                return {"state": "unreachable" if path == "/robots.txt" else "none", "text": ""}
            if response.status in (301, 302, 303, 307, 308) and response.header("location"):
                url = urljoin(url, response.header("location"))
                continue
            if 200 <= response.status < 300:
                return {"state": "ok", "text": response.body.decode("utf-8", errors="replace")}
            if response.status == 429:
                self.pacer.rest(target.host, retry_after_seconds(response.header("retry-after")))
                return {"state": "unreachable", "text": ""}
            if 400 <= response.status < 500:
                return {"state": "none", "text": ""}  # RFC 9309: an unavailable file allows everything
            return {"state": "unreachable" if path == "/robots.txt" else "none", "text": ""}
        return {"state": "none", "text": ""}

    def _check_rules(self, url, target, deadline_at):
        robots_rules, ai_rules = self._rules_for(target, deadline_at)
        if robots_rules is None:
            outcome = Outcome(url, error="Nollie could not check this site's robots.txt (the site did not answer), "
                                         "so it will not read the site for now. Try again later.", refused=True,
                              cache=False)
            return outcome, None
        if not robots_rules.allowed(self.token, target.path):
            return _refusal(url, "This site's robots.txt asks Nollie not to read this page, so Nollie stopped. "
                                 "If a person should look, share the link with them."), None
        signals = robots_rules.content_signals(self.token)
        if signals.get("ai-input") is False:
            return _refusal(url, "This site says its pages should not be used as input for AI answers "
                                 "(Content-Signal ai-input=no), so Nollie stopped. Share the link if a person "
                                 "should read it."), None
        if ai_rules is not None and not ai_rules.allowed(self.token, target.path):
            return _refusal(url, "This site's ai.txt asks AI tools not to use this page, so Nollie stopped. "
                                 "Share the link if a person should read it."), None
        return None, robots_rules.crawl_delay(self.token)

    def _read(self, url, target, markdown, deadline_at):
        seen = set()
        for _ in range(MAX_REDIRECTS + 1):
            if target.url in seen:
                return Outcome(url, error="This page redirects in a loop.", cache=False)
            seen.add(target.url)
            try:
                netsafe.resolve_public(target, self.resolver, self.allowed)
                refusal, crawl_delay = self._check_rules(url, target, deadline_at)
                if refusal is not None:
                    return refusal
                response = self._request(target, deadline_at, crawl_delay=crawl_delay, max_bytes=MAX_PDF)
            except netsafe.Refused as refused:
                return _refusal(url, f"{refused.reason} Nollie stopped.")
            except Resting as resting:
                outcome = _refusal(url, resting.message)
                outcome.cache = False
                return outcome
            except LookupError as missing:
                return Outcome(url, error=str(missing), cache=False)
            except TimeoutError:
                return Outcome(url, error="Nollie ran out of time waiting its turn for this site. Try again shortly.",
                               cache=False)
            except (ConnectionError, OSError) as failed:
                return Outcome(url, error=str(failed) or "The site did not answer.", cache=False)

            location = response.header("location")
            if response.status in (301, 302, 303, 307, 308) and location:
                try:
                    target = netsafe.normalize(urljoin(target.url, location))
                except netsafe.Refused as refused:
                    return _refusal(url, f"The page redirected somewhere Nollie will not go. {refused.reason} "
                                         "Nollie stopped.")
                continue
            return self._finish(url, target, response, markdown)
        return Outcome(url, error="This page redirects too many times.", cache=False)

    def _finish(self, url, target, response, markdown):
        status = response.status
        if status == 429 or status == 503:
            self.pacer.rest(target.host, retry_after_seconds(response.header("retry-after"), self.clock()))
        if status in _PERSON:
            if looks_like_challenge(response):
                return _challenge(url, status)
            return _person(url, _PERSON[status], status)
        if status >= 400:
            if looks_like_challenge(response):
                return _challenge(url, status)
            return Outcome(url, error=f"The page answered HTTP {status}.", status=status, cache=False)
        if status < 200 or status >= 300:
            return Outcome(url, error=f"The page answered HTTP {status}.", status=status, cache=False)

        header_signals = rules.PageSignals.from_directives(
            rules.header_directives(response.all("x-robots-tag"), self.token))
        if header_signals.refuse_ai:
            return _refusal(url, "This page asks AI tools not to use it (noai), so Nollie stopped. "
                                 "Share the link if a person should read it.", status=status)
        content_type = response.header("content-type").lower()
        base = content_type.split(";", 1)[0].strip()
        body = response.body
        if base in _HTML_TYPES or (not base and body.lstrip()[:15].lower().startswith((b"<!doctype html", b"<html"))):
            outcome = self._html(url, target, response, markdown, header_signals)
        elif base == "application/pdf" or body[:5] == b"%PDF-":
            outcome = self._pdf(url, response)
        elif base.startswith("text/") or base in _TEXT_TYPES or base.endswith(("+json", "+xml")):
            text = extract.decode_html(body, content_type)
            outcome = Outcome(url, title="", text=text[:MAX_TEXT_OUT], kind="text")
        else:
            outcome = Outcome(url, error=f"Nollie reads web pages, PDFs and text, not {base or 'this kind of file'}.",
                              status=status)
        outcome.final_url, outcome.status = response.url, status
        if response.truncated and not outcome.error:
            outcome.notes.append("the page was very large; Nollie read the first part")
        if header_signals.no_archive and not outcome.error:
            outcome.cache = False
        return outcome

    def _html(self, url, target, response, markdown, header_signals):
        html = extract.decode_html(response.body[:MAX_HTML], response.header("content-type"))
        title, text, metas = extract.read_html_basic(html, markdown)
        page_signals = rules.PageSignals.from_directives(rules.meta_directives(metas, self.token))
        if page_signals.refuse_ai:
            return _refusal(url, "This page asks AI tools not to use it (noai), so Nollie stopped. "
                                 "Share the link if a person should read it.", status=response.status)
        if looks_like_challenge(response, len(text)):
            return _challenge(url, response.status)
        better = self.helper.html(html, response.url, markdown) if self.helper else None
        if better:
            title, text = better[0] or title, better[1]
            engine = "trafilatura"
        else:
            engine = "standard library"
        outcome = Outcome(url, title=title, text=text[:MAX_TEXT_OUT], kind="html")
        outcome.notes.append(f"text by {engine}")
        if header_signals.no_images or page_signals.no_images:
            outcome.text = _strip_images(outcome.text)
            outcome.notes.append("the site asks AI tools to leave its images alone")
        if page_signals.no_archive:
            outcome.cache = False
        if not outcome.text.strip():
            return Outcome(url, error="The page had no readable text. It may need a browser; ask a person to open it.",
                           status=response.status, cache=False)
        return outcome

    def _pdf(self, url, response):
        if response.truncated:
            return Outcome(url, error="This PDF is too large for Nollie to read.", status=response.status)
        if not self.helper or not self.helper.capabilities()["pdf"]:
            return Outcome(url, error="This is a PDF, and Nollie's PDF reader is not installed on this Mac. "
                                      "Run the reader installer with --with-extractors.", status=response.status,
                           cache=False)
        scratch = ensure_dir(self.root / "tmp")
        fd, path = tempfile.mkstemp(suffix=".pdf", dir=scratch)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(response.body)
            done = self.helper.pdf(path)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        if done is None:
            return Outcome(url, error="Nollie could not read the text in this PDF.", status=response.status)
        title, text = done
        if not text.strip():
            return Outcome(url, error="This PDF has no text layer (it may be scanned pages).", status=response.status)
        return Outcome(url, title=title, text=text[:MAX_TEXT_OUT], kind="pdf", notes=["text by pypdf"])

    def _remember_handoff(self, outcome):
        try:
            host = netsafe.normalize(outcome.url).host
        except netsafe.Refused:
            return
        with locked_json(self.root / "handoffs.json", {}) as data:
            now = self.clock()
            for key in [k for k, v in data.items() if v.get("until", 0) < now]:
                data.pop(key, None)
            data[host] = {"until": now + HANDOFF_TTL, "status": outcome.status}


def _strip_images(text):
    import re
    return re.sub(r"\s*\[image: [^\]]*\]\s*", " ", text)


def handoff_for(root, url, clock=time.time):
    """The recent 'wants a person' record for this URL's site, if any."""
    try:
        host = netsafe.normalize(url).host
    except netsafe.Refused:
        return None
    record = read_json(Path(root) / "handoffs.json", {}).get(host)
    if record and record.get("until", 0) > clock():
        return record
    return None
