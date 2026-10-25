"""Offline checks for the appcast a Direct release publishes."""
import unittest

import check_appcast as appcast

NS = 'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'


def feed(*items):
    return f'<?xml version="1.0" standalone="yes"?><rss {NS} version="2.0"><channel><title>Nollie</title>{"".join(items)}</channel></rss>'


def item(version="0.2", build="3", tag=None, signature=' sparkle:edSignature="abc=="', length="100"):
    tag = tag or f"v{version}"
    return (f"<item><title>{version}</title><sparkle:version>{build}</sparkle:version>"
            f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
            f'<enclosure url="https://github.com/kozarski/nollie/releases/download/{tag}/Nollie.zip" length="{length}"{signature}/></item>')


class AppcastTests(unittest.TestCase):
    def test_a_signed_item_for_this_release_is_fit(self):
        self.assertEqual(appcast.problems(feed(item()), "v0.2", 100), [])

    def test_earlier_releases_may_follow_the_newest(self):
        self.assertEqual(appcast.problems(feed(item(), item("0.1", "2")), "v0.2", 100), [])

    def test_a_missing_signature_a_wrong_length_or_a_wrong_download_are_each_caught(self):
        self.assertTrue(appcast.problems(feed(item(signature="")), "v0.2", 100))
        self.assertTrue(appcast.problems(feed(item(length="99")), "v0.2", 100))
        self.assertTrue(appcast.problems(feed(item(tag="v0.1")), "v0.2", 100))

    def test_an_appcast_without_this_version_or_with_it_buried_is_caught(self):
        self.assertTrue(appcast.problems(feed(item("0.1", "2")), "v0.2"))
        self.assertTrue(appcast.problems(feed(item("0.1", "2"), item()), "v0.2"))
        self.assertTrue(appcast.problems(feed(), "v0.2"))
        self.assertTrue(appcast.problems("not xml", "v0.2"))


if __name__ == "__main__":
    unittest.main()
