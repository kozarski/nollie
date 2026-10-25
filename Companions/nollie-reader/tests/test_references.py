import json
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import parse_qs, urlsplit
import unittest

import support

modules = support.load()
netsafe, references, limits = modules["netsafe"], modules["references"], modules["limits"]
UA = "Nollie/0.1 (+https://nollie.app/bot)"

ARXIV = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
 <entry><id>http://arxiv.org/abs/2101.00001v1</id><published>2021-01-01T00:00:00Z</published>
  <title>A Study of Things</title><summary>We study things.</summary>
  <author><name>Ada Lovelace</name></author>
  <link title="pdf" href="http://arxiv.org/pdf/2101.00001v1"/></entry>
</feed>"""


def j(value, status=200, headers=None):
    return (status, {"Content-Type": "application/json", **(headers or {})}, json.dumps(value))


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.site = support.Site()
        self.addCleanup(self.site.close)
        resolver, allowed = support.test_network(netsafe, {"refs.example.com": "127.0.0.1"})

        def fetch(target, headers):
            local = netsafe.normalize(f"http://refs.example.com:{self.site.port}/{target.host}{target.path}")
            return netsafe.fetch_once(local, headers=headers, resolver=resolver, allowed=allowed)

        self.clock = Clock()
        self.refs = references.References(Path(self.temp.name), fetch=fetch, clock=self.clock, sleep=self.clock.sleep)

    def route(self, path, reply):
        self.site.routes[path] = reply

    def query_of(self, index=-1):
        return parse_qs(urlsplit(self.site.hits[index][0]).query)

    def test_wikipedia_search_and_page(self):
        self.route("/en.wikipedia.org/w/rest.php/v1/search/page", j({"pages": [
            {"key": "Ada_Lovelace", "title": "Ada Lovelace", "description": "Mathematician",
             "excerpt": "<span class=\"searchmatch\">Ada</span> Lovelace was"}]}))
        result = self.refs.lookup("wikipedia", query="ada lovelace", limit=3)
        self.assertTrue(result["ok"])
        row = result["results"][0]
        self.assertEqual(row["url"], "https://en.wikipedia.org/wiki/Ada_Lovelace")
        self.assertEqual(row["summary"], "Mathematician Ada Lovelace was")
        self.assertEqual(self.query_of()["limit"], ["3"])
        self.assertEqual(self.site.hits[-1][1]["User-Agent"], UA)
        self.route("/fr.wikipedia.org/w/api.php", j({"query": {"pages": [{"title": "Ada Lovelace", "extract": "Texte."}]}}))
        page = self.refs.lookup("wikipedia", id="Ada Lovelace", language="fr")
        self.assertEqual(page["results"][0]["text"], "Texte.")
        self.assertEqual(self.query_of()["titles"], ["Ada Lovelace"])

    def test_wikidata_entity(self):
        self.route("/www.wikidata.org/wiki/Special:EntityData/Q7259.json", j({"entities": {"Q7259": {
            "id": "Q7259", "labels": {"en": {"value": "Ada Lovelace"}}, "descriptions": {"en": {"value": "mathematician"}},
            "aliases": {"en": [{"value": "Augusta Ada King"}]}, "sitelinks": {"enwiki": {"title": "Ada Lovelace"}},
            "claims": {"P569": [{"mainsnak": {"datavalue": {"value": {"time": "+1815-12-10T00:00:00Z"}}}}]}}}}))
        row = self.refs.lookup("wikidata", id="Q7259")["results"][0]
        self.assertEqual(row["facts"]["P569"], ["+1815-12-10T00:00:00Z"])
        self.assertEqual(row["wikipedia"], "https://en.wikipedia.org/wiki/Ada_Lovelace")
        self.assertFalse(self.refs.lookup("wikidata", id="DROP TABLE")["ok"])

    def test_arxiv_waits_three_seconds_between_requests(self):
        self.route("/export.arxiv.org/api/query", (200, {"Content-Type": "application/atom+xml"}, ARXIV))
        first = self.refs.lookup("arxiv", query="things")
        self.assertEqual(first["results"][0]["authors"], ["Ada Lovelace"])
        self.assertEqual(first["results"][0]["pdf"], "http://arxiv.org/pdf/2101.00001v1")
        self.assertEqual(self.query_of()["search_query"], ["all:things"])
        self.refs.lookup("arxiv", query="au:lovelace")
        self.assertEqual(self.query_of()["search_query"], ["au:lovelace"])
        self.assertEqual(self.clock.sleeps, [3.0])

    def test_crossref_doi_and_pubmed(self):
        self.route("/api.crossref.org/works/10.1000%2Fxyz", j({"message": {
            "DOI": "10.1000/xyz", "title": ["Paper"], "author": [{"given": "Ada", "family": "Lovelace"}],
            "issued": {"date-parts": [[1843]]}, "container-title": ["Notes"], "URL": "https://doi.org/10.1000/xyz"}}))
        row = self.refs.lookup("crossref", id="https://doi.org/10.1000/xyz")["results"][0]
        self.assertEqual((row["year"], row["authors"], row["venue"]), (1843, ["Ada Lovelace"], "Notes"))
        self.route("/eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi", j({"esearchresult": {"idlist": ["111"]}}))
        self.route("/eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi", j({"result": {"111": {
            "title": "A trial", "source": "BMJ", "pubdate": "2020", "authors": [{"name": "Smith J"}]}}}))
        rows = self.refs.lookup("pubmed", query="trial")["results"]
        self.assertEqual(rows[0]["url"], "https://pubmed.ncbi.nlm.nih.gov/111/")
        self.assertEqual(self.query_of()["tool"], ["nollie"])

    def test_github_hackernews_archive(self):
        self.route("/api.github.com/search/repositories", j({"items": [
            {"full_name": "a/b", "html_url": "https://github.com/a/b", "description": "tool", "stargazers_count": 5}]}))
        self.assertEqual(self.refs.lookup("github", query="tool")["results"][0]["stars"], 5)
        self.route("/hn.algolia.com/api/v1/search", j({"hits": [{"title": "Show HN", "objectID": "42", "points": 9}]}))
        self.assertEqual(self.refs.lookup("hackernews", query="show")["results"][0]["url"],
                         "https://news.ycombinator.com/item?id=42")
        self.route("/archive.org/advancedsearch.php", j({"response": {"docs": [
            {"identifier": "old-film", "title": "Old Film", "year": "1925", "mediatype": "movies"}]}}))
        self.assertEqual(self.refs.lookup("archive", query="film")["results"][0]["url"],
                         "https://archive.org/details/old-film")

    def test_answers_are_cached_for_an_hour(self):
        self.route("/hn.algolia.com/api/v1/search", j({"hits": []}))
        self.refs.lookup("hackernews", query="same")
        self.refs.lookup("hackernews", query="same")
        self.assertEqual(len(self.site.hits), 1)
        self.clock.now += 3601
        self.refs.lookup("hackernews", query="same")
        self.assertEqual(len(self.site.hits), 2)

    def test_a_source_that_says_no_wants_a_person(self):
        self.route("/api.crossref.org/works", (403, {}, "no"))
        result = self.refs.lookup("crossref", query="x")
        self.assertFalse(result["ok"])
        self.assertTrue(result["wants_person"])
        self.assertIn("wants a person", result["error"])

    def test_slow_down_rests_the_source_for_every_bot(self):
        self.route("/hn.algolia.com/api/v1/search", (429, {"Retry-After": "300"}, "slow"))
        self.assertIn("slow down", self.refs.lookup("hackernews", query="a")["error"])
        self.assertIn("resting", self.refs.lookup("hackernews", query="b")["error"])
        self.assertEqual(len(self.site.hits), 1)
        self.clock.now += 301
        self.route("/hn.algolia.com/api/v1/search", j({"hits": []}))
        self.assertTrue(self.refs.lookup("hackernews", query="c")["ok"])

    def test_github_rate_limit_is_a_rest_not_a_refusal(self):
        self.route("/api.github.com/search/repositories",
                   (403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(int(self.clock.now) + 600)}, "{}"))
        result = self.refs.lookup("github", query="x")
        self.assertNotIn("wants_person", result)
        self.assertIn("slow down", result["error"])

    def test_daily_cap(self):
        refs = references.References(Path(self.temp.name), fetch=self.refs.fetch, clock=self.clock, sleep=self.clock.sleep,
                                     limits=limits.ServiceLimits(self.temp.name, clock=self.clock, sleep=self.clock.sleep,
                                                                 services={"wikipedia": {"interval": 0, "daily": 1}}))
        self.route("/en.wikipedia.org/w/rest.php/v1/search/page", j({"pages": []}))
        self.assertTrue(refs.lookup("wikipedia", query="one")["ok"])
        self.assertIn("tomorrow", refs.lookup("wikipedia", query="two")["error"])

    def test_bad_input(self):
        self.assertFalse(self.refs.lookup("google", query="x")["ok"])
        self.assertFalse(self.refs.lookup("wikipedia")["ok"])
        self.assertFalse(self.refs.lookup("github", id="../../etc")["ok"])
        self.assertEqual(self.site.hits, [])


if __name__ == "__main__":
    unittest.main()
