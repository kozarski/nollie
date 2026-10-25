from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import support

modules = support.load()
netsafe, reader_mod, extract = modules["netsafe"], modules["reader"], modules["extract"]
UA = "Nollie/0.1 (+https://nollie.app/bot)"
VENV_PYTHON = Path(__file__).resolve().parents[3] / "build" / "reader-venv" / "bin" / "python"

ARTICLE = """<!doctype html><html><head><title>Garden notes</title>
<meta name="description" content="x"></head><body>
<header class="site-header"><a href="/">Home</a> Menu Login</header>
<nav><a href="/a">A</a><a href="/b">B</a></nav>
<div class="cookie-banner">We use cookies. Accept?</div>
<main><article><h1>Growing tomatoes</h1>
<p>Tomatoes like <b>sun</b> and steady water.</p>
<ul><li>Water in the morning</li><li>Stake the stems</li></ul>
<img src="t.jpg" alt="Ripe tomatoes">
<table><tr><th>Month</th><th>Task</th></tr><tr><td>May</td><td>Plant</td></tr></table>
</article></main>
<aside>Related posts</aside><footer>Copyright</footer>
<script>var tracking = 1;</script></body></html>"""
OK_ROBOTS = (200, {"Content-Type": "text/plain"}, "User-agent: *\nAllow: /\n")


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class ReaderTestCase(unittest.TestCase):
    names = ("news.example.com", "other.example.com")

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.site = support.Site({"/robots.txt": OK_ROBOTS})
        self.addCleanup(self.site.close)
        mapping = {name: "127.0.0.1" for name in self.names}
        mapping.update({"internal.example.com": "10.0.0.7", "meta.example.com": "169.254.169.254"})
        self.resolver, self.allowed = support.test_network(netsafe, mapping)
        self.clock = Clock()
        self.reader = self.make_reader()

    def make_reader(self, **kwargs):
        options = dict(resolver=self.resolver, allowed=self.allowed, clock=self.clock, sleep=self.clock.sleep,
                       helper=extract.Helper(None))
        options.update(kwargs)
        return reader_mod.Reader(self.root, **options)

    def url(self, path, host="news.example.com"):
        return f"http://{host}:{self.site.port}{path}"

    def page_hits(self):
        return [p for p in self.site.paths() if p not in ("/robots.txt", "/ai.txt")]


class ReadingTests(ReaderTestCase):
    def test_reads_clean_text_with_its_own_agent(self):
        self.site.routes["/garden"] = (200, {"Content-Type": "text/html; charset=utf-8"}, ARTICLE)
        result = self.reader.read(self.url("/garden"))
        self.assertNotIn("error", result)
        self.assertEqual(result["title"], "Garden notes")
        text = result["content"]
        for kept in ("# Growing tomatoes", "Tomatoes like sun and steady water.", "- Water in the morning",
                     "Month | Task", "[image: Ripe tomatoes]"):
            self.assertIn(kept, text)
        for dropped in ("Menu Login", "cookies", "Related posts", "Copyright", "tracking"):
            self.assertNotIn(dropped, text)
        self.assertEqual(self.site.paths(), ["/robots.txt", "/ai.txt", "/garden"])
        for _, headers in self.site.hits:
            self.assertEqual(headers["User-Agent"], UA)
            self.assertNotIn("Cookie", headers)
        self.assertEqual(result["metadata"]["sourceURL"], self.url("/garden"))

    def test_plain_text_and_unknown_types(self):
        self.site.routes["/notes.txt"] = (200, {"Content-Type": "text/plain"}, "just text")
        self.site.routes["/photo"] = (200, {"Content-Type": "image/png"}, b"\x89PNG....")
        self.assertEqual(self.reader.read(self.url("/notes.txt"))["content"], "just text")
        self.assertIn("not image/png", self.reader.read(self.url("/photo"))["error"])

    def test_pdf_without_the_helper_says_so(self):
        self.site.routes["/paper.pdf"] = (200, {"Content-Type": "application/pdf"}, b"%PDF-1.4 ...")
        result = self.reader.read(self.url("/paper.pdf"))
        self.assertIn("PDF reader is not installed", result["error"])
        self.assertNotIn("blocked_by_policy", result)

    def test_many_pages_keep_their_order(self):
        for name in ("a", "b", "c"):
            self.site.routes[f"/{name}"] = (200, {"Content-Type": "text/plain"}, name * 3)
        urls = [self.url("/a"), self.url("/b", "other.example.com"), "http://localhost/x", self.url("/c")]
        results = self.reader.read_many(urls)
        self.assertEqual([r.get("content") for r in results[:2]], ["aaa", "bbb"])
        self.assertTrue(results[2]["blocked_by_policy"])
        self.assertEqual(results[3]["content"], "ccc")


class SafetyTests(ReaderTestCase):
    def test_redirect_to_metadata_address_is_refused(self):
        self.site.routes["/go"] = (302, {"Location": "http://169.254.169.254/latest/meta-data/"}, "")
        result = self.reader.read(self.url("/go"))
        self.assertTrue(result["blocked_by_policy"])
        self.assertIn("redirected somewhere Nollie will not go", result["error"])

    def test_redirect_to_a_name_that_resolves_private_is_refused(self):
        self.site.routes["/go"] = (301, {"Location": f"http://internal.example.com:{self.site.port}/admin"}, "")
        self.site.routes["/admin"] = (200, {"Content-Type": "text/plain"}, "secret")
        result = self.reader.read(self.url("/go"))
        self.assertTrue(result["blocked_by_policy"])
        self.assertIn("private or internal address", result["error"])
        self.assertNotIn("/admin", self.site.paths())

    def test_name_resolving_to_metadata_is_refused_before_any_request(self):
        result = self.reader.read(f"http://meta.example.com:{self.site.port}/")
        self.assertTrue(result["blocked_by_policy"])
        self.assertEqual(self.site.hits, [])

    def test_redirect_to_another_site_checks_that_sites_rules(self):
        self.site.routes["/hop"] = (302, {"Location": self.url("/landing", "other.example.com")}, "")
        self.site.routes["/landing"] = (200, {"Content-Type": "text/plain"}, "landed")
        result = self.reader.read(self.url("/hop"))
        self.assertEqual(result["content"], "landed")
        self.assertEqual(result["metadata"]["finalURL"], self.url("/landing", "other.example.com"))
        hosts = [h["Host"].split(":")[0] for p, h in self.site.hits if p == "/robots.txt"]
        self.assertEqual(hosts, ["news.example.com", "other.example.com"])

    def test_redirect_loops_stop(self):
        self.site.routes["/loop"] = (302, {"Location": "/loop2"}, "")
        self.site.routes["/loop2"] = (302, {"Location": "/loop"}, "")
        self.assertIn("loop", self.reader.read(self.url("/loop"))["error"])


class SiteRulesTests(ReaderTestCase):
    def test_robots_disallow_for_nollie(self):
        self.site.routes["/robots.txt"] = (200, {}, "User-agent: *\nAllow: /\n\nUser-agent: Nollie\nDisallow: /members\n")
        self.site.routes["/members/list"] = (200, {}, "names")
        result = self.reader.read(self.url("/members/list"))
        self.assertTrue(result["blocked_by_policy"])
        self.assertIn("robots.txt asks Nollie not to read", result["error"])
        self.assertEqual(self.page_hits(), [])

    def test_missing_robots_allows_and_failing_robots_waits(self):
        self.site.routes["/robots.txt"] = (404, {}, "")
        self.site.routes["/page"] = (200, {"Content-Type": "text/plain"}, "fine")
        self.assertEqual(self.reader.read(self.url("/page"))["content"], "fine")
        self.site.routes["/robots.txt"] = (500, {}, "")
        result = self.reader.read(self.url("/page", "other.example.com"))
        self.assertTrue(result["blocked_by_policy"])
        self.assertIn("could not check this site's robots.txt", result["error"])

    def test_content_signal_ai_input_no(self):
        self.site.routes["/robots.txt"] = (200, {}, "User-agent: *\nContent-Signal: search=yes, ai-input=no\nAllow: /\n")
        self.site.routes["/story"] = (200, {"Content-Type": "text/plain"}, "story")
        result = self.reader.read(self.url("/story"))
        self.assertIn("ai-input=no", result["error"])
        self.assertEqual(self.page_hits(), [])

    def test_ai_txt_disallow(self):
        self.site.routes["/ai.txt"] = (200, {"Content-Type": "text/plain"}, "User-Agent: *\nDisallow: /\n")
        self.site.routes["/story"] = (200, {"Content-Type": "text/plain"}, "story")
        result = self.reader.read(self.url("/story"))
        self.assertIn("ai.txt asks AI tools", result["error"])
        self.assertTrue(result["blocked_by_policy"])
        self.assertEqual(self.page_hits(), [])

    def test_ai_txt_html_soft_404_is_ignored(self):
        self.site.routes["/ai.txt"] = (200, {"Content-Type": "text/html"}, "<html>Not found</html>")
        self.site.routes["/story"] = (200, {"Content-Type": "text/plain"}, "story")
        self.assertEqual(self.reader.read(self.url("/story"))["content"], "story")

    def test_x_robots_tag_and_meta_noai(self):
        self.site.routes["/h"] = (200, {"Content-Type": "text/plain", "X-Robots-Tag": "noai"}, "x")
        self.site.routes["/scoped"] = (200, {"Content-Type": "text/plain", "X-Robots-Tag": "otherbot: noai"}, "ok")
        self.site.routes["/m"] = (200, {"Content-Type": "text/html"},
                                  '<html><head><meta name="robots" content="noai"></head><body><p>x</p></body></html>')
        self.assertIn("(noai)", self.reader.read(self.url("/h"))["error"])
        self.assertEqual(self.reader.read(self.url("/scoped"))["content"], "ok")
        self.assertTrue(self.reader.read(self.url("/m"))["blocked_by_policy"])

    def test_noimageai_drops_image_descriptions(self):
        page = ARTICLE.replace("<head>", '<head><meta name="nollie" content="noimageai">')
        self.site.routes["/g"] = (200, {"Content-Type": "text/html"}, page)
        result = self.reader.read(self.url("/g"))
        self.assertNotIn("[image:", result["content"])
        self.assertIn("Growing tomatoes", result["content"])


class WantsAPersonTests(ReaderTestCase):
    def test_sign_in_block_and_slow_down_want_a_person(self):
        for status in (401, 403, 429):
            self.site.routes[f"/s{status}"] = (status, {"Content-Type": "text/html"}, "<p>no</p>")
            result = self.reader.read(self.url(f"/s{status}", "other.example.com" if status == 429 else "news.example.com"))
            self.assertTrue(result["error"].startswith("This site wants a person"), result["error"])
            self.assertTrue(result["blocked_by_policy"])
            self.assertIn("will not try another tool or service", result["error"])

    def test_slow_down_rests_the_site_for_every_bot(self):
        self.site.routes["/busy"] = (429, {"Retry-After": "120"}, "slow down")
        self.site.routes["/later"] = (200, {"Content-Type": "text/plain"}, "later")
        self.reader.read(self.url("/busy"))
        other_bot = self.make_reader()
        result = other_bot.read(self.url("/later"))
        self.assertIn("asked bots to slow down", result["error"])
        self.assertNotIn("/later", self.site.paths())
        self.clock.now += 121
        self.assertEqual(other_bot.read(self.url("/later"))["content"], "later")

    def test_challenge_pages(self):
        self.site.routes["/cf"] = (503, {"Content-Type": "text/html", "cf-mitigated": "challenge"},
                                   "<title>Just a moment...</title>")
        self.site.routes["/widget"] = (200, {"Content-Type": "text/html"},
                                       '<html><body><p>Checking</p><div class="g-recaptcha"></div></body></html>')
        long_story = "<html><body><article>" + "<p>An essay about why a captcha annoys readers.</p>" * 60 + "</article></body></html>"
        self.site.routes["/essay"] = (200, {"Content-Type": "text/html"}, long_story)
        self.assertIn("human check", self.reader.read(self.url("/cf"))["error"])
        self.assertIn("human check", self.reader.read(self.url("/widget", "other.example.com"))["error"])
        self.assertIn("captcha annoys", self.reader.read(self.url("/essay", "other.example.com"))["content"])

    def test_handoff_blocks_the_browser_for_that_site(self):
        glue_guard = _guard(self.root)
        self.site.routes["/locked"] = (403, {}, "no")
        self.reader.read(self.url("/locked"))
        record = reader_mod.handoff_for(self.root, self.url("/other"), clock=self.clock)
        self.assertEqual(record["status"], 403)
        blocked = glue_guard(tool_name="browser_navigate", args={"url": self.url("/other")})
        self.assertEqual(blocked["action"], "block")
        self.assertIsNone(glue_guard(tool_name="browser_navigate", args={"url": "https://elsewhere.example.org/"}))


def _guard(root):
    # hermes_glue imports Hermes only inside its functions, so the guard is testable alone.
    import importlib
    glue = importlib.import_module("nollie_reader_under_test.hermes_glue")
    return glue.guard(root)


class CacheAndPacingTests(ReaderTestCase):
    def test_one_hour_cache_shared_between_bots(self):
        self.site.routes["/c"] = (200, {"Content-Type": "text/plain"}, "cached text")
        self.reader.read(self.url("/c"))
        result = self.make_reader().read(self.url("/c"))
        self.assertEqual(result["content"], "cached text")
        self.assertEqual(self.page_hits(), ["/c"])
        self.clock.now += 3601
        self.make_reader().read(self.url("/c"))
        self.assertEqual(self.page_hits(), ["/c", "/c"])

    def test_refusals_are_cached_too(self):
        self.site.routes["/no"] = (403, {}, "no")
        self.reader.read(self.url("/no"))
        self.assertTrue(self.make_reader().read(self.url("/no"))["blocked_by_policy"])
        self.assertEqual(self.page_hits(), ["/no"])

    def test_noarchive_is_never_stored(self):
        self.site.routes["/fresh"] = (200, {"Content-Type": "text/plain", "X-Robots-Tag": "noarchive"}, "fresh")
        self.reader.read(self.url("/fresh"))
        self.reader.read(self.url("/fresh"))
        self.assertEqual(self.page_hits(), ["/fresh", "/fresh"])

    def test_waits_between_requests_to_the_same_site(self):
        for name in ("p1", "p2"):
            self.site.routes[f"/{name}"] = (200, {"Content-Type": "text/plain"}, name)
        self.reader.read(self.url("/p1"))
        self.reader.read(self.url("/p2"))
        # robots, ai.txt, p1, p2: each waits two seconds after the last.
        self.assertEqual(self.clock.sleeps, [2.0, 2.0, 2.0])

    def test_crawl_delay_is_honoured(self):
        self.site.routes["/robots.txt"] = (200, {}, "User-agent: *\nCrawl-delay: 5\nAllow: /\n")
        for name in ("p1", "p2"):
            self.site.routes[f"/{name}"] = (200, {"Content-Type": "text/plain"}, name)
        self.reader.read(self.url("/p1"))
        self.reader.read(self.url("/p2"))
        self.assertEqual(self.clock.sleeps[-1], 5.0)


@unittest.skipUnless(VENV_PYTHON.is_file(), "build/reader-venv not present")
class ExtractorTests(ReaderTestCase):
    def test_trafilatura_reads_the_article(self):
        reader = self.make_reader(helper=extract.Helper(str(VENV_PYTHON)))
        self.site.routes["/garden"] = (200, {"Content-Type": "text/html"}, ARTICLE.replace(
            "<p>Tomatoes", "<p>" + "Tomatoes grow well in warm gardens with good soil. " * 8 + "</p><p>Tomatoes"))
        result = reader.read(self.url("/garden"))
        self.assertIn("Tomatoes like", result["content"])
        self.assertNotIn("cookies", result["content"])
        self.assertIn("text by trafilatura", result["metadata"]["notes"])

    def test_pypdf_reads_a_pdf(self):
        reader = self.make_reader(helper=extract.Helper(str(VENV_PYTHON)))
        self.site.routes["/paper.pdf"] = (200, {"Content-Type": "application/pdf"}, _tiny_pdf("Hello from a PDF"))
        result = reader.read(self.url("/paper.pdf"))
        self.assertIn("Hello from a PDF", result["content"])


def _tiny_pdf(text):
    stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
               b"/Resources << /Font << /F1 5 0 R >> >> >>",
               b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


if __name__ == "__main__":
    unittest.main()
