import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location("payments_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

KEY = re.compile(r"^plugin_rule:nollie-ask-first:buy:[0-9a-f]{32}$")
PREFIX = "/api/plugins/nollie-workflow/payments"
TEST_NUMBER = "4242424242424242"


class RouteTests(unittest.TestCase):
    def setUp(self):
        mock.payments_rest("POST", "/api/_mock/payments", {}, {"reset": True})

    def test_cards_are_labels_only(self):
        status, body = mock.payments_rest("GET", PREFIX + "/cards", {}, None)
        self.assertEqual(status, 200)
        self.assertEqual([c["last4"] for c in body["cards"]], ["4242", "4444"])
        self.assertNotIn(TEST_NUMBER, str(body))
        number = dict(id="c", brand="visa", last4="4242", number=TEST_NUMBER)
        self.assertEqual(mock.payments_rest("PUT", PREFIX + "/cards", {}, {"cards": [number]})[0], 422)
        self.assertEqual(mock.payments_rest("PUT", PREFIX + "/cards", {}, {"cards": [{"id": "c", "brand": "visa",
                                                                                         "last4": TEST_NUMBER}]})[0], 422)

    def test_every_switch_starts_off_and_round_trips(self):
        self.assertEqual(mock.payments_rest("GET", PREFIX + "/bots", {"bot": "work"}, None), (200, {"bot": "work", "on": False}))
        self.assertEqual(mock.payments_rest("PUT", PREFIX + "/bots", {}, {"bot": "work", "on": True}), (200, {"bot": "work", "on": True}))
        self.assertEqual(mock.payments_rest("GET", PREFIX + "/bots", {"bot": "work"}, None)[1]["on"], True)

    def test_private_and_unknown_bots_are_refused(self):
        self.assertEqual(mock.payments_rest("GET", PREFIX + "/bots", {"bot": "moss"}, None)[0], 403)
        self.assertEqual(mock.payments_rest("PUT", PREFIX + "/bots", {}, {"bot": "moss", "on": True})[0], 403)
        self.assertEqual(mock.payments_rest("GET", PREFIX + "/bots", {"bot": "nobody"}, None)[0], 404)
        self.assertEqual(mock.payments_rest("GET", PREFIX + "/bots", {"bot": "../x"}, None)[0], 422)
        self.assertIsNone(mock.payments_rest("GET", "/api/plugins/nollie-workflow/other", {}, None))


class Played(mock.Gateway):
    def __init__(self, answer):
        super().__init__(None)
        self.answer = answer
        self.events = []
        self.asked = []

    async def event(self, kind, sid, payload=None):
        self.events.append((kind, payload or {}))

    async def ask(self, method, sid, params, timeout=300):
        self.asked.append((method, params))
        return self.answer

    async def stream_words(self, s, text, delay=0.0, kind="message.delta"):
        await self.event(kind, s.sid, {"text": text})


class BuyCardTests(unittest.IsolatedAsyncioTestCase):
    async def turn(self, answer):
        gateway = Played(answer)
        await gateway._run_turn(mock.Session("sid", "stored", "Chat", "default"), "ask first pay")
        return gateway

    async def test_a_payment_waits_on_the_buy_card_with_the_macs_words(self):
        gateway = await self.turn({"choice": "once"})
        [(method, params)] = gateway.asked
        self.assertEqual(method, "approval")
        self.assertRegex(params["pattern_key"], KEY)
        self.assertEqual(params["description"].split("\n")[0], "Pay £48.99 to shop.example.com with Visa ending 4242.")
        self.assertIn("tool.complete", [k for k, _ in gateway.events])
        self.assertNotIn(TEST_NUMBER, str(gateway.events) + str(gateway.asked))

    async def test_deny_pays_nothing(self):
        for answer in ({"choice": "deny"}, None):
            gateway = await self.turn(answer)
            self.assertNotIn("tool.complete", [k for k, _ in gateway.events])


if __name__ == "__main__":
    unittest.main()
