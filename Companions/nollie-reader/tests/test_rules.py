import unittest

import support

rules = support.load()["rules"]

ROBOTS = """
# comments are ignored
User-agent: *
Disallow: /private/
Allow: /private/open
Crawl-delay: 4

User-agent: Nollie
User-agent: helperbot
Disallow: /no-nollie
Disallow: /*.pdf$
Allow: /no-nollie/but-this
Content-Signal: search=yes, ai-input=yes

User-agent: otherbot
Disallow: /
"""


class RobotsTests(unittest.TestCase):
    def setUp(self):
        self.robots = rules.parse(ROBOTS)

    def test_own_group_wins_over_star(self):
        self.assertFalse(self.robots.allowed("nollie", "/no-nollie/page"))
        # The star group does not apply once a named group matches.
        self.assertTrue(self.robots.allowed("nollie", "/private/anything"))
        self.assertTrue(self.robots.allowed("Nollie", "/no-nollie/but-this/page"))

    def test_star_group_applies_to_unnamed_agents(self):
        self.assertFalse(self.robots.allowed("somebot", "/private/x"))
        self.assertTrue(self.robots.allowed("somebot", "/private/open/x"))
        self.assertEqual(self.robots.crawl_delay("somebot"), 4)
        self.assertIsNone(self.robots.crawl_delay("nollie"))

    def test_wildcards_and_end_anchor(self):
        self.assertFalse(self.robots.allowed("nollie", "/files/report.pdf"))
        self.assertTrue(self.robots.allowed("nollie", "/files/report.pdf?download=1"))

    def test_longest_match_and_allow_on_tie(self):
        robots = rules.parse("User-agent: *\nDisallow: /a\nAllow: /a\nDisallow: /b/c\nAllow: /b\n")
        self.assertTrue(robots.allowed("nollie", "/a/page"))
        self.assertFalse(robots.allowed("nollie", "/b/c/d"))
        self.assertTrue(robots.allowed("nollie", "/b/x"))

    def test_percent_encoding_matches_both_ways(self):
        robots = rules.parse("User-agent: *\nDisallow: /caf%C3%A9\n")
        self.assertFalse(robots.allowed("nollie", "/café/menu"))
        self.assertFalse(robots.allowed("nollie", "/caf%C3%A9/menu"))

    def test_empty_disallow_and_robots_file_itself(self):
        robots = rules.parse("User-agent: *\nDisallow:\n")
        self.assertTrue(robots.allowed("nollie", "/anything"))
        everything = rules.parse("User-agent: *\nDisallow: /\n")
        self.assertFalse(everything.allowed("nollie", "/x"))
        self.assertTrue(everything.allowed("nollie", "/robots.txt"))

    def test_content_signals(self):
        self.assertTrue(self.robots.content_signals("nollie")["ai-input"])
        refusing = rules.parse("Content-Signal: ai-input=no\nUser-agent: *\nAllow: /\n")
        self.assertFalse(refusing.content_signals("nollie")["ai-input"])
        grouped = rules.parse("User-agent: *\nContent-Signal: search=yes, ai-train=no, ai-input=no\nAllow: /\n")
        self.assertEqual(grouped.content_signals("nollie"), {"search": True, "ai-train": False, "ai-input": False})


class PageSignalTests(unittest.TestCase):
    def test_x_robots_tag_scoping(self):
        self.assertIn("noai", rules.header_directives(["noai, noimageai"], "nollie"))
        self.assertIn("noai", rules.header_directives(["nollie: noai"], "nollie"))
        self.assertNotIn("noai", rules.header_directives(["otherbot: noai", "noindex"], "nollie"))

    def test_meta_names(self):
        metas = [("robots", "noimageai"), ("nollie", "noai"), ("description", "noai")]
        found = rules.meta_directives(metas, "nollie")
        signals = rules.PageSignals.from_directives(found)
        self.assertTrue(signals.refuse_ai)
        self.assertTrue(signals.no_images)
        self.assertFalse(rules.PageSignals.from_directives({"noindex", "nofollow"}).refuse_ai)
        self.assertTrue(rules.PageSignals.from_directives({"noarchive"}).no_archive)


if __name__ == "__main__":
    unittest.main()
