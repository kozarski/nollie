"""Free official reference sources through their public APIs, with the same politeness as the
reader: Nollie's user agent, public addresses only, shared per-source pacing and daily caps,
an hour of caching, and "wants a person" instead of a workaround when a source says no.

These are documented APIs meant for programs, so their robots.txt (written for crawlers) is not
consulted. Search engines are never scraped and no archive copies of paywalled pages are used.
"""
from __future__ import annotations

import html
import json
import re
import time
from urllib.parse import quote, urlencode
import xml.etree.ElementTree as ET

from . import netsafe
from .cache import Cache
from .limits import LABELS, Resting, ServiceLimits, retry_after_seconds
from .state import shared_root

SOURCES = ("wikipedia", "wikidata", "arxiv", "crossref", "pubmed", "github", "hackernews", "archive")
MAX_TEXT = 20_000
_LANG = re.compile(r"^[a-z]{2,3}(?:-[a-z0-9]+)?$")
_ATOM = {"a": "http://www.w3.org/2005/Atom", "arxiv": "http://arxiv.org/schemas/atom"}


class SourceError(Exception):
    def __init__(self, message, refused=False):
        super().__init__(message)
        self.message, self.refused = message, refused


def _plain(value, limit=600):
    text = html.unescape(re.sub(r"<[^>]+>", " ", value or ""))
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _row(title, url, summary="", **extra):
    row = {"title": _plain(title, 300), "url": url, "summary": _plain(summary)}
    row.update({k: v for k, v in extra.items() if v not in (None, "", [], {})})
    return row


class References:
    def __init__(self, root=None, *, limits=None, cache=None, fetch=None, clock=time.time, sleep=time.sleep):
        root = root or shared_root()
        self.limits = limits or ServiceLimits(root, clock=clock, sleep=sleep)
        self.cache = cache or Cache(root, clock=clock)
        self.fetch = fetch or (lambda target, headers: netsafe.fetch_once(target, headers=headers, timeout=20.0,
                                                                          max_bytes=4_000_000))

    # ---- transport ---------------------------------------------------------------------

    def _get(self, service, url, accept="application/json", headers=None):
        key = [service, url, accept]
        cached = self.cache.get("ref", key)
        if cached is not None:
            return cached
        label = LABELS.get(service, service)
        try:
            target = netsafe.normalize(url)
            self.limits.acquire(service)
            response = self.fetch(target, {"Accept": accept, **(headers or {})})
        except Resting as resting:
            raise SourceError(f"{resting.message} Try another source, or try again later.")
        except netsafe.Refused as refused:
            raise SourceError(refused.reason, refused=True)
        except (LookupError, ConnectionError, OSError):
            raise SourceError(f"{label} did not answer. Try again later.")
        status = response.status
        limited = (status == 403 and response.header("x-ratelimit-remaining") == "0")
        if status in (429, 503) or limited:
            wait = retry_after_seconds(response.header("retry-after"))
            reset = response.header("x-ratelimit-reset")
            if wait is None and reset.isdigit():
                wait = max(0.0, float(reset) - time.time())
            self.limits.report(service, "slow", wait)
            raise SourceError(f"{label} asked Nollie to slow down, so it is resting for now. "
                              "Try another source, or try again later.")
        if status in (401, 402, 403, 407, 451):
            raise SourceError(f"This source wants a person (HTTP {status}). Nollie stopped and will not try "
                              "another way in. Share the link and ask a person to open it.", refused=True)
        if status == 404:
            raise SourceError(f"{label} has nothing at that id.")
        if not 200 <= status < 300:
            raise SourceError(f"{label} answered HTTP {status}.")
        self.limits.report(service, "ok")
        text = response.body.decode("utf-8", errors="replace")
        self.cache.put("ref", key, text)
        return text

    def _json(self, service, url, **kwargs):
        try:
            return json.loads(self._get(service, url, **kwargs))
        except ValueError:
            raise SourceError(f"{LABELS.get(service, service)} sent something Nollie could not read.")

    # ---- entry point -------------------------------------------------------------------

    def lookup(self, source, query="", id="", limit=5, language="en"):
        source = (source or "").strip().lower()
        if source not in SOURCES:
            return {"ok": False, "error": f"Unknown source. Use one of: {', '.join(SOURCES)}."}
        query, id = (query or "").strip(), (id or "").strip()
        if not query and not id:
            return {"ok": False, "error": "Give a query to search, or an id to open."}
        try:
            limit = min(max(int(limit), 1), 10)
        except (TypeError, ValueError):
            limit = 5
        language = (language or "en").strip().lower()
        if not _LANG.match(language):
            language = "en"
        try:
            handler = getattr(self, f"_{source}")
            results = handler(query, id, limit, language)
        except SourceError as error:
            out = {"ok": False, "source": source, "error": error.message}
            if error.refused:
                out["wants_person"] = True
            return out
        except (KeyError, TypeError, IndexError, AttributeError, ET.ParseError):
            return {"ok": False, "source": source,
                    "error": f"{LABELS[source]} answered in a shape Nollie did not expect."}
        return {"ok": True, "source": source, "results": results}

    # ---- sources -----------------------------------------------------------------------

    def _wikipedia(self, query, id, limit, lang):
        base = f"https://{lang}.wikipedia.org"
        if id:
            data = self._json("wikipedia", f"{base}/w/api.php?" + urlencode({
                "action": "query", "prop": "extracts", "explaintext": 1, "redirects": 1, "format": "json",
                "formatversion": 2, "titles": id}))
            page = data["query"]["pages"][0]
            if page.get("missing"):
                raise SourceError("Wikipedia has no page with that title.")
            title = page["title"]
            return [{"title": title, "url": f"{base}/wiki/{quote(title.replace(' ', '_'))}",
                     "text": (page.get("extract") or "")[:MAX_TEXT]}]
        data = self._json("wikipedia", f"{base}/w/rest.php/v1/search/page?" + urlencode({"q": query, "limit": limit}))
        return [_row(p.get("title"), f"{base}/wiki/{quote(p.get('key', ''))}",
                     " ".join(x for x in (p.get("description"), p.get("excerpt")) if x))
                for p in data.get("pages", [])]

    def _wikidata(self, query, id, limit, lang):
        if id:
            if not re.fullmatch(r"[QP]\d{1,12}", id):
                raise SourceError("A Wikidata id looks like Q42.")
            data = self._json("wikidata", f"https://www.wikidata.org/wiki/Special:EntityData/{id}.json")
            entity = data["entities"][next(iter(data["entities"]))]
            pick = lambda field: (entity.get(field, {}).get(lang) or entity.get(field, {}).get("en") or {}).get("value", "")
            facts = {}
            for prop, claims in list(entity.get("claims", {}).items())[:40]:
                values = []
                for claim in claims[:3]:
                    value = claim.get("mainsnak", {}).get("datavalue", {}).get("value")
                    if isinstance(value, dict):
                        value = value.get("id") or value.get("time") or value.get("amount") or value.get("text")
                    if isinstance(value, (str, int, float)):
                        values.append(str(value))
                if values:
                    facts[prop] = values
            link = (entity.get("sitelinks", {}).get(f"{lang}wiki") or {}).get("title")
            return [_row(pick("labels"), f"https://www.wikidata.org/wiki/{entity.get('id', id)}", pick("descriptions"),
                         id=entity.get("id", id),
                         aliases=[a["value"] for a in entity.get("aliases", {}).get(lang, [])][:10],
                         wikipedia=f"https://{lang}.wikipedia.org/wiki/{quote(link.replace(' ', '_'))}" if link else None,
                         facts=facts)]
        data = self._json("wikidata", "https://www.wikidata.org/w/api.php?" + urlencode({
            "action": "wbsearchentities", "search": query, "language": lang, "uselang": lang, "type": "item",
            "format": "json", "limit": limit}))
        return [_row(s.get("label") or s.get("id"), s.get("concepturi") or f"https://www.wikidata.org/wiki/{s.get('id')}",
                     s.get("description", ""), id=s.get("id")) for s in data.get("search", [])]

    def _arxiv(self, query, id, limit, lang):
        params = ({"id_list": id} if id else
                  {"search_query": query if re.match(r"^(ti|au|abs|co|jr|cat|rn|id|all):", query) else f"all:{query}",
                   "start": 0, "max_results": limit})
        text = self._get("arxiv", "https://export.arxiv.org/api/query?" + urlencode(params),
                         accept="application/atom+xml")
        root = ET.fromstring(text)
        rows = []
        for entry in root.findall("a:entry", _ATOM):
            link = entry.findtext("a:id", default="", namespaces=_ATOM).strip()
            pdf = next((l.get("href") for l in entry.findall("a:link", _ATOM) if l.get("title") == "pdf"), None)
            rows.append(_row(entry.findtext("a:title", default="", namespaces=_ATOM), link,
                             entry.findtext("a:summary", default="", namespaces=_ATOM),
                             published=entry.findtext("a:published", default="", namespaces=_ATOM)[:10],
                             authors=[a.findtext("a:name", default="", namespaces=_ATOM)
                                      for a in entry.findall("a:author", _ATOM)][:12], pdf=pdf))
        return rows

    def _crossref(self, query, id, limit, lang):
        def row(item):
            issued = (item.get("issued", {}).get("date-parts") or [[None]])[0]
            authors = [" ".join(x for x in (a.get("given"), a.get("family")) if x) for a in item.get("author", [])][:12]
            return _row((item.get("title") or [""])[0], item.get("URL") or f"https://doi.org/{item.get('DOI', '')}",
                        item.get("abstract", ""), doi=item.get("DOI"), authors=authors,
                        venue=(item.get("container-title") or [""])[0],
                        year=issued[0] if issued else None, type=item.get("type"))
        if id:
            doi = re.sub(r"^(https?://(dx\.)?doi\.org/|doi:)", "", id, flags=re.I)
            data = self._json("crossref", f"https://api.crossref.org/works/{quote(doi, safe='')}")
            return [row(data["message"])]
        data = self._json("crossref", "https://api.crossref.org/works?" + urlencode({
            "query": query, "rows": limit,
            "select": "DOI,title,author,issued,container-title,URL,type,abstract"}))
        return [row(item) for item in data["message"].get("items", [])]

    def _pubmed(self, query, id, limit, lang):
        base = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
        if id:
            if not id.isdigit():
                raise SourceError("A PubMed id is a number, like 31452104.")
            text = self._get("pubmed", f"{base}/efetch.fcgi?" + urlencode({
                "db": "pubmed", "id": id, "rettype": "abstract", "retmode": "text", "tool": "nollie"}),
                accept="text/plain")
            return [{"title": f"PubMed {id}", "url": f"https://pubmed.ncbi.nlm.nih.gov/{id}/", "text": text[:MAX_TEXT]}]
        found = self._json("pubmed", f"{base}/esearch.fcgi?" + urlencode({
            "db": "pubmed", "term": query, "retmode": "json", "retmax": limit, "tool": "nollie"}))
        ids = found["esearchresult"].get("idlist", [])[:limit]
        if not ids:
            return []
        summary = self._json("pubmed", f"{base}/esummary.fcgi?" + urlencode({
            "db": "pubmed", "id": ",".join(ids), "retmode": "json", "tool": "nollie"}))["result"]
        return [_row(summary[i].get("title"), f"https://pubmed.ncbi.nlm.nih.gov/{i}/", "", id=i,
                     journal=summary[i].get("source"), date=summary[i].get("pubdate"),
                     authors=[a.get("name") for a in summary[i].get("authors", [])][:12])
                for i in ids if i in summary]

    def _github(self, query, id, limit, lang):
        headers = {"X-GitHub-Api-Version": "2022-11-28"}
        if id:
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", id):
                raise SourceError("A GitHub id looks like owner/repo.")
            repo = self._json("github", f"https://api.github.com/repos/{id}", accept="application/vnd.github+json",
                              headers=headers)
            try:
                readme = self._get("github", f"https://api.github.com/repos/{id}/readme",
                                   accept="application/vnd.github.raw+json", headers=headers)
            except SourceError:
                readme = ""
            return [_row(repo.get("full_name"), repo.get("html_url"), repo.get("description") or "",
                         stars=repo.get("stargazers_count"), language=repo.get("language"),
                         license=(repo.get("license") or {}).get("spdx_id"), updated=repo.get("pushed_at"),
                         readme=readme[:MAX_TEXT])]
        data = self._json("github", "https://api.github.com/search/repositories?" + urlencode({
            "q": query, "per_page": limit}), accept="application/vnd.github+json", headers=headers)
        return [_row(r.get("full_name"), r.get("html_url"), r.get("description") or "", stars=r.get("stargazers_count"),
                     language=r.get("language"), updated=r.get("pushed_at")) for r in data.get("items", [])]

    def _hackernews(self, query, id, limit, lang):
        if id:
            if not id.isdigit():
                raise SourceError("A Hacker News id is a number.")
            item = self._json("hackernews", f"https://hacker-news.firebaseio.com/v0/item/{id}.json")
            if not item:
                raise SourceError("Hacker News has nothing at that id.")
            return [_row(item.get("title") or f"Item {id}", f"https://news.ycombinator.com/item?id={id}",
                         item.get("text", ""), link=item.get("url"), points=item.get("score"),
                         by=item.get("by"), comments=item.get("descendants"))]
        data = self._json("hackernews", "https://hn.algolia.com/api/v1/search?" + urlencode({
            "query": query, "tags": "story", "hitsPerPage": limit}))
        return [_row(h.get("title"), f"https://news.ycombinator.com/item?id={h.get('objectID')}", "",
                     link=h.get("url"), points=h.get("points"), comments=h.get("num_comments"),
                     date=(h.get("created_at") or "")[:10]) for h in data.get("hits", [])]

    def _archive(self, query, id, limit, lang):
        if id:
            if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", id):
                raise SourceError("An Internet Archive id looks like the last part of an archive.org/details link.")
            data = self._json("archive", f"https://archive.org/metadata/{id}")
            meta = data.get("metadata") or {}
            if not meta:
                raise SourceError("The Internet Archive has nothing at that id.")
            first = lambda v: v[0] if isinstance(v, list) and v else v
            return [_row(first(meta.get("title")) or id, f"https://archive.org/details/{id}",
                         first(meta.get("description")) or "", creator=first(meta.get("creator")),
                         date=first(meta.get("date")), kind=meta.get("mediatype"),
                         files=len(data.get("files") or []))]
        params = [("q", query)] + [("fl[]", f) for f in ("identifier", "title", "description", "year", "mediatype", "creator")]
        params += [("rows", limit), ("page", 1), ("output", "json")]
        data = self._json("archive", "https://archive.org/advancedsearch.php?" + urlencode(params))
        first = lambda v: v[0] if isinstance(v, list) and v else v
        return [_row(first(d.get("title")) or d.get("identifier"), f"https://archive.org/details/{d.get('identifier')}",
                     first(d.get("description")) or "", id=d.get("identifier"), year=d.get("year"),
                     kind=d.get("mediatype"), creator=first(d.get("creator")))
                for d in data.get("response", {}).get("docs", [])]


DESCRIPTION = (
    "Look things up in free official reference sources: wikipedia, wikidata, arxiv, crossref (DOIs), pubmed, "
    "github (repositories), hackernews and archive (Internet Archive collections). Give a query to search, or an id "
    "to open one record: a Wikipedia title, a Wikidata Q-id, an arXiv id, a DOI, a PubMed id, owner/repo, a Hacker "
    "News item id or an archive.org identifier. Every bot shares polite limits, so a source may be resting; then use "
    "another source or say so. If a source wants a person, share the link instead of trying another way."
)
SCHEMA = {
    "name": "reference_lookup", "description": DESCRIPTION,
    "parameters": {
        "type": "object", "additionalProperties": False,
        "properties": {
            "source": {"type": "string", "enum": list(SOURCES)},
            "query": {"type": "string", "description": "What to search for."},
            "id": {"type": "string", "description": "Open one record by its id instead of searching."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5},
            "language": {"type": "string", "description": "Wikipedia and Wikidata language code, default en."},
        },
        "required": ["source"],
    },
}
