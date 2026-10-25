import importlib.util
import re
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ask_first_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

KEY = re.compile(r"^plugin_rule:nollie-ask-first:send:[0-9a-f]{32}$")


class Played(mock.Gateway):
    """The gateway with its socket swapped for a list, and one answer ready for the card."""

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


class AskFirstTurnTests(unittest.IsolatedAsyncioTestCase):
    async def turn(self, prompt, answer):
        gateway = Played(answer)
        session = mock.Session("sid", "stored", "Chat", "default")
        await gateway._run_turn(session, prompt)
        return gateway, session

    def reply(self, gateway):
        return next(p["text"] for k, p in gateway.events if k == "message.complete")

    async def test_an_email_is_held_with_the_whole_action(self):
        gateway, _ = await self.turn("ask first email", {"choice": "once"})
        [(method, params)] = gateway.asked
        self.assertEqual(method, "approval")
        self.assertRegex(params["pattern_key"], KEY)
        self.assertEqual(params["command"], "<mcp__gmail__send_email> (plugin approval rule)")
        self.assertEqual(params["description"], "Send with gmail: send email\nto: sam@example.com\n"
                                                "subject: Lunch on Friday\nbody: Are you free at noon?")
        self.assertTrue(self.reply(gateway).endswith("Sent."))
        self.assertIn("tool.complete", [k for k, _ in gateway.events])

    async def test_a_click_ends_with_the_check_line(self):
        gateway, _ = await self.turn("ask first click", {"choice": "once"})
        [(_, params)] = gateway.asked
        self.assertRegex(params["pattern_key"], KEY)
        self.assertEqual(params["description"].split("\n"),
                         ["Press “Send” on its computer.",
                          "You're about to press “Send”."])

    async def test_each_hold_has_a_fresh_key(self):
        first, _ = await self.turn("ask first email", {"choice": "once"})
        second, _ = await self.turn("ask first email", {"choice": "once"})
        self.assertNotEqual(first.asked[0][1]["pattern_key"], second.asked[0][1]["pattern_key"])

    async def test_deny_or_no_answer_sends_nothing(self):
        for answer in ({"choice": "deny"}, None):
            gateway, session = await self.turn("ask first email", answer)
            self.assertTrue(self.reply(gateway).endswith("Okay, I didn't send it."))
            self.assertNotIn("tool.complete", [k for k, _ in gateway.events])
            self.assertEqual([r["role"] for r in session.history], ["user", "assistant", "assistant"])


if __name__ == "__main__":
    unittest.main()
