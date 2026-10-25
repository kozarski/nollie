from tempfile import TemporaryDirectory
import types
import unittest

import support

modules = support.load()
limits, search_limits = modules["limits"], modules["search_limits"]


def fake_keyless_module(calls):
    """The shape Hermes 0.22 uses: vendor functions looked up by name when the ring runs."""
    module = types.ModuleType("fake_keyless_mcp")
    ring = ("exa", "parallel", "firecrawl", "keenable")

    def maker(vendor):
        def search(query, limit=5):
            calls.append(vendor)
            return {"success": True, "data": {"web": [{"url": f"https://{vendor}.example/{query}"}]}}

        def extract(urls):
            calls.append(vendor + ":extract")
            return [{"url": u, "title": "", "content": "text"} for u in urls]
        return search, extract

    for vendor in ring:
        search, extract = maker(vendor)
        setattr(module, f"{vendor}_search_keyless", search)
        setattr(module, f"{vendor}_extract_keyless", extract)
    module._KEYLESS_SEARCHERS = {v: (lambda q, l, _v=v: getattr(module, f"{_v}_search_keyless")(q, l)) for v in ring}

    def search_with_failover(name, query, limit=5):
        start = ring.index(name)
        for vendor in ring[start:] + ring[:start]:
            result = module._KEYLESS_SEARCHERS[vendor](query, limit)
            error = (result.get("error") or "").lower()
            if result.get("success") or not any(m in error for m in ("rate limit", "quota exceeded")):
                return result
        return result

    module.search_with_failover = search_with_failover
    return module


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class SearchLimitTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.calls = []
        self.module = fake_keyless_module(self.calls)
        self.clock = Clock()
        self.limits = limits.ServiceLimits(self.temp.name, clock=self.clock, sleep=self.clock.sleep,
                                           services={"exa": {"interval": 1, "daily": 2}})
        search_limits.install(self.module, self.temp.name, limits=self.limits)
        self.addCleanup(search_limits.uninstall)

    def test_capped_exa_hands_over_to_parallel(self):
        for _ in range(2):
            self.assertEqual(self.module.search_with_failover("exa", "q")["data"]["web"][0]["url"], "https://exa.example/q")
        result = self.module.search_with_failover("exa", "q")
        self.assertEqual(result["data"]["web"][0]["url"], "https://parallel.example/q")
        self.assertEqual(self.calls, ["exa", "exa", "parallel"])

    def test_slow_down_reply_rests_the_service(self):
        original = search_limits._installed["originals"][(id(self.module), "parallel_search_keyless")][1]
        replies = iter([{"success": False, "error": "Keyless Parallel search failed: HTTP 429: Too Many Requests"}])
        wrapped = search_limits._search_wrapper("parallel", lambda q, l=5: next(replies, None) or original(q, l),
                                                self.limits)
        self.module.parallel_search_keyless = wrapped
        self.module.search_with_failover("parallel", "q")
        status = self.limits.status()["parallel"]
        self.assertIsNotNone(status["resting_until"])
        result = self.module.search_with_failover("parallel", "again")
        self.assertEqual(result["data"]["web"][0]["url"], "https://firecrawl.example/again")

    def test_extract_counts_each_page(self):
        self.module.exa_extract_keyless(["https://a.example/1", "https://a.example/2"])
        pages = self.module.exa_extract_keyless(["https://a.example/3"])
        self.assertIn("paused", pages[0]["error"])
        self.assertIn("quota exceeded", pages[0]["error"])  # a phrase the ring treats as a rate limit

    def test_install_is_idempotent_and_uninstall_restores(self):
        wrapped = self.module.exa_search_keyless
        search_limits.install(self.module, self.temp.name, limits=self.limits)
        self.assertIs(self.module.exa_search_keyless, wrapped)
        search_limits.uninstall()
        self.assertTrue(getattr(self.module.exa_search_keyless, "_nollie_limited", False))
        search_limits.uninstall()
        self.assertFalse(getattr(self.module.exa_search_keyless, "_nollie_limited", False))
        search_limits.install(self.module, self.temp.name, limits=self.limits)  # for the cleanup


if __name__ == "__main__":
    unittest.main()
