"""The mock's skill locks, the Keep skills switch, each bot's model spending and the priced tool's approval."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("skills_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

KEEP = "/api/plugins/nollie-workflow/keep-skills"


class SkillLockTests(unittest.TestCase):
    def setUp(self):
        mock.skills_rest("POST", "/api/_mock/skills", {}, {"reset": True})

    def locked(self, bot="default"):
        status, rows = mock.skills_rest("GET", "/api/skills", {"profile": bot}, None)
        self.assertEqual(status, 200)
        return {row["name"] for row in rows if row["locked"]}

    def test_rows_carry_their_lock_per_bot(self):
        self.assertEqual(self.locked(), {"incident-writeup"})
        self.assertEqual(self.locked("work"), set())

    def test_lock_and_unlock_one_skill(self):
        answer = mock.skills_rest("PUT", "/api/skills/lock", {"profile": "work"}, {"name": "code-review", "locked": True})
        self.assertEqual(answer, (200, {"ok": True, "name": "code-review", "locked": True}))
        self.assertEqual(self.locked("work"), {"code-review"})
        self.assertEqual(self.locked(), {"incident-writeup"})
        mock.skills_rest("PUT", "/api/skills/lock", {"profile": "work"}, {"name": "code-review", "locked": False})
        self.assertEqual(self.locked("work"), set())
        self.assertEqual(mock.skills_rest("PUT", "/api/skills/lock", {}, {"name": "nope", "locked": True})[0], 404)
        self.assertEqual(mock.skills_rest("GET", "/api/skills/lock", {}, None)[0], 405)

    def test_keep_skills_switch_and_a_new_skill(self):
        self.assertEqual(mock.skills_rest("GET", KEEP, {"bot": "work"}, None), (200, {"bot": "work", "on": False}))
        mock.skills_rest("POST", "/api/_mock/skills", {}, {"bot": "work", "made": "loose-notes"})
        self.assertNotIn("loose-notes", self.locked("work"))
        self.assertEqual(mock.skills_rest("PUT", KEEP, {}, {"bot": "work", "on": True}), (200, {"bot": "work", "on": True}))
        mock.skills_rest("POST", "/api/_mock/skills", {}, {"bot": "work", "made": "kept-notes"})
        self.assertIn("kept-notes", self.locked("work"))

    def test_keep_skills_refuses_private_and_unknown_bots(self):
        self.assertEqual(mock.skills_rest("GET", KEEP, {"bot": "moss"}, None)[0], 403)
        self.assertEqual(mock.skills_rest("PUT", KEEP, {}, {"bot": "moss", "on": True})[0], 403)
        self.assertEqual(mock.skills_rest("GET", KEEP, {"bot": "nobody"}, None)[0], 404)
        self.assertEqual(mock.skills_rest("GET", KEEP, {"bot": "../x"}, None)[0], 422)
        self.assertEqual(mock.skills_rest("PUT", KEEP, {}, {"bot": "work", "on": "yes"})[0], 422)
        self.assertEqual(mock.skills_rest("DELETE", KEEP, {}, None)[0], 405)
        self.assertIsNone(mock.skills_rest("GET", "/api/plugins/nollie-workflow/other", {}, None))


class SpendTests(unittest.TestCase):
    def test_a_cloud_model_costs_and_a_local_one_does_not(self):
        _, cloud = mock._usage_analytics_route({"days": "7", "profile": "default"})
        _, local = mock._usage_analytics_route({"days": "7", "profile": "work"})
        self.assertGreater(cloud["totals"]["total_estimated_cost"], 0)
        self.assertEqual(local["totals"]["total_estimated_cost"], 0)
        self.assertEqual(sum(m["estimated_cost"] for m in local["by_model"]), 0)
        self.assertGreater(local["totals"]["total_input"], 0)


class PaidToolTests(unittest.TestCase):
    def test_the_words_are_hermes_own(self):
        words = mock.Gateway.PAID_TOOL_COMMAND
        self.assertTrue(words.startswith("MCP tool 'get_quote' on UNTRUSTED server 'quotes' wants to run. Costs about 5 credits."))
        self.assertIn("This chat has used about 10 credits on 'quotes' (limit 50).", words)
        self.assertEqual(mock.Gateway._script_for("paid tool please", mock.Gateway._LATE_SCRIPTS), "_paid_tool_turn")


if __name__ == "__main__":
    unittest.main()
