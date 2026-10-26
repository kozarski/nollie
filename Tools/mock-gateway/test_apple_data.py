import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location("apple_data_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

KEY = re.compile(r"^plugin_rule:nollie-ask-first:calendar:[0-9a-f]{32}$")
PATH = "/api/plugins/nollie-workflow/apple-data/bots"


class SwitchTests(unittest.TestCase):
    def setUp(self):
        mock.apple_data_rest("POST", "/api/_mock/apple-data", {}, {"reset": True})

    def test_every_switch_starts_off_and_round_trips(self):
        self.assertEqual(mock.apple_data_rest("GET", PATH, {"bot": "work"}, None),
                         (200, {"bot": "work", "on": [], "mac": {"calendar": "allowed", "reminders": "allowed",
                                                                  "contacts": "allowed"}}))
        status, body = mock.apple_data_rest("PUT", PATH, {}, {"bot": "work", "on": ["contacts", "calendar"]})
        self.assertEqual((status, body["on"]), (200, ["calendar", "contacts"]))
        self.assertEqual(mock.apple_data_rest("GET", PATH, {"bot": "work"}, None)[1]["on"], ["calendar", "contacts"])

    def test_bad_names_private_bots_and_unknown_switches_are_refused(self):
        self.assertEqual(mock.apple_data_rest("GET", PATH, {"bot": "moss"}, None)[0], 403)
        self.assertEqual(mock.apple_data_rest("GET", PATH, {"bot": "nobody"}, None)[0], 404)
        self.assertEqual(mock.apple_data_rest("GET", PATH, {"bot": "../x"}, None)[0], 422)
        self.assertEqual(mock.apple_data_rest("PUT", PATH, {}, {"bot": "work", "on": ["photos"]})[0], 422)
        self.assertIsNone(mock.apple_data_rest("GET", "/api/plugins/nollie-workflow/other", {}, None))

    def test_the_fixture_sets_switches_and_the_macs_answer(self):
        mock.apple_data_rest("POST", "/api/_mock/apple-data", {}, {"bot": "default", "on": ["calendar"],
                                                                    "mac": {"calendar": "not_asked"}})
        body = mock.apple_data_rest("GET", PATH, {"bot": "default"}, None)[1]
        self.assertEqual((body["on"], body["mac"]["calendar"]), (["calendar"], "not_asked"))


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


class CalendarCardTests(unittest.IsolatedAsyncioTestCase):
    async def turn(self, answer):
        gateway = Played(answer)
        await gateway._run_turn(mock.Session("sid", "stored", "Chat", "default"), "ask first calendar")
        return gateway

    async def test_a_calendar_change_waits_with_the_macs_words(self):
        gateway = await self.turn({"choice": "once"})
        [(method, params)] = gateway.asked
        self.assertEqual(method, "approval")
        self.assertRegex(params["pattern_key"], KEY)
        self.assertEqual(params["description"].split("\n"),
                         ["Add “Dentist” on Tue 3 Nov, 10:00 to Home calendar?", "Until 11:00"])
        self.assertIn("tool.complete", [k for k, _ in gateway.events])

    async def test_deny_leaves_the_calendar_alone(self):
        for answer in ({"choice": "deny"}, None):
            gateway = await self.turn(answer)
            self.assertNotIn("tool.complete", [k for k, _ in gateway.events])


if __name__ == "__main__":
    unittest.main()
