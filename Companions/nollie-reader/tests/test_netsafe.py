import unittest

import support

modules = support.load()
netsafe = modules["netsafe"]


class AddressTests(unittest.TestCase):
    def test_only_public_addresses(self):
        refused = ["127.0.0.1", "10.1.2.3", "172.16.0.9", "192.168.1.1", "169.254.169.254", "100.100.100.200",
                   "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "::1", "fe80::1", "fd00:ec2::254",
                   "::ffff:10.0.0.1", "::ffff:169.254.169.254", "2002:a00:1::1", "64:ff9b::a00:1", "::"]
        for address in refused:
            self.assertFalse(netsafe.address_allowed(address), address)
        for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "::ffff:8.8.8.8"]:
            self.assertTrue(netsafe.address_allowed(address), address)

    def test_urls_refused_before_any_lookup(self):
        for url in ["file:///etc/passwd", "ftp://example.com/x", "http://user:pw@example.com/",
                    "http://localhost/", "http://printer.local/", "http://metadata.google.internal/",
                    "http://db.internal/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/",
                    "http://10.0.0.1/", "http://intranet/", "http://router.home.arpa/", "not a url", ""]:
            with self.assertRaises(netsafe.Refused, msg=url):
                netsafe.normalize(url)

    def test_normalize_keeps_query_and_drops_fragment(self):
        target = netsafe.normalize("HTTPS://Example.COM/a b?q=1#part")
        self.assertEqual(target.url, "https://example.com/a%20b?q=1")
        self.assertEqual((target.host, target.port, target.path), ("example.com", 443, "/a%20b?q=1"))
        self.assertEqual(netsafe.normalize("http://example.com:8080").origin, "http://example.com:8080")

    def test_one_private_answer_refuses_the_name(self):
        target = netsafe.normalize("https://mixed.example.com/")
        with self.assertRaises(netsafe.Refused):
            netsafe.resolve_public(target, lambda host, port: ["93.184.215.14", "10.0.0.8"])
        self.assertEqual(netsafe.resolve_public(target, lambda host, port: ["93.184.215.14"]), ["93.184.215.14"])

    def test_connection_goes_to_the_checked_address_with_the_real_host_name(self):
        site = support.Site({"/": (200, {"Content-Type": "text/plain"}, "hello")})
        self.addCleanup(site.close)
        resolver, allowed = support.test_network(netsafe, {"pinned.example.com": "127.0.0.1"})
        response = netsafe.fetch_once(netsafe.normalize(f"http://pinned.example.com:{site.port}/"),
                                      resolver=resolver, allowed=allowed)
        self.assertEqual(response.body, b"hello")
        path, headers = site.hits[0]
        self.assertEqual(headers["Host"], f"pinned.example.com:{site.port}")
        self.assertEqual(headers["User-Agent"], "Nollie/0.1 (+https://nollie.app/bot)")
        self.assertNotIn("Cookie", headers)

    def test_real_rules_refuse_the_loopback_server(self):
        site = support.Site({"/": (200, {}, "secret")})
        self.addCleanup(site.close)
        target = netsafe.normalize(f"http://looks-public.example.com:{site.port}/")
        with self.assertRaises(netsafe.Refused):
            netsafe.fetch_once(target, resolver=lambda host, port: ["127.0.0.1"])
        self.assertEqual(site.hits, [])

    def test_compressed_bodies_are_limited(self):
        import gzip
        bomb = gzip.compress(b"a" * 5_000_000)
        site = support.Site({"/": (200, {"Content-Encoding": "gzip"}, bomb)})
        self.addCleanup(site.close)
        resolver, allowed = support.test_network(netsafe, {"zip.example.com": "127.0.0.1"})
        response = netsafe.fetch_once(netsafe.normalize(f"http://zip.example.com:{site.port}/"), max_bytes=1000,
                                      resolver=resolver, allowed=allowed)
        self.assertTrue(response.truncated)
        self.assertEqual(response.body, b"")

    def test_a_site_that_drips_data_is_cut_off(self):
        import time

        def drip(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "100000")
            handler.end_headers()
            try:
                for _ in range(40):
                    handler.wfile.write(b"x" * 10)
                    handler.wfile.flush()
                    time.sleep(0.05)
            except OSError:
                pass  # the reader hung up, as it should

        site = support.Site({"/": drip})
        self.addCleanup(site.close)
        resolver, allowed = support.test_network(netsafe, {"slow.example.com": "127.0.0.1"})
        started = time.monotonic()
        with self.assertRaises(ConnectionError):
            netsafe.fetch_once(netsafe.normalize(f"http://slow.example.com:{site.port}/"), resolver=resolver,
                               allowed=allowed, timeout=5, total_timeout=0.5)
        self.assertLess(time.monotonic() - started, 1.5)


if __name__ == "__main__":
    unittest.main()
