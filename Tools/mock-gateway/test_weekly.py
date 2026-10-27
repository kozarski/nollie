import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest


spec = importlib.util.spec_from_file_location("weekly_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

ROUTE = "/api/plugins/nollie-workflow/week"
# The keys nollie-workflow's week route answers with (Companions/nollie-workflow/weekly.py and the route).
KEYS = {"bot", "days", "now", "since", "recording_since", "papertrail", "replies", "places", "places_more", "answers",
        "asks", "earlier_answers", "schedules", "runs_kept", "schedules_kept", "board", "apps", "web", "filter"}


class WeeklyFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        mock.NEUTRAL_MODELS = False
        self.jobs = copy.deepcopy(mock.CRON_JOBS)

    def tearDown(self):
        mock.PRIVATE_BOTS["profiles"] = None
        mock.WEEK_SWITCHES.clear()
        mock.WEEK["state"] = "busy"
        mock.CRON_JOBS[:] = self.jobs
        mock.CREATED_PROFILES.clear()

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body), response.headers

    def test_each_seeded_bot_answers_in_the_add_ons_shape(self):
        for bot in ("default", "work"):
            status, body, headers = self.request(f"{ROUTE}?bot={bot}")
            self.assertEqual((status, headers["Cache-Control"]), (200, "no-store"))
            self.assertEqual(set(body), KEYS)
            self.assertEqual(body["bot"], bot)
            self.assertTrue(all(place["first_at"] <= body["now"] for place in body["places"]))

    def test_the_busy_week_has_something_new_and_more_questions_than_usual(self):
        _, body, _ = self.request(ROUTE + "?bot=default")
        new = [place for place in body["places"] if place["first_at"] >= body["since"]]
        self.assertEqual([place["host"] for place in new], ["mcp.notes.example.com"])
        self.assertLessEqual(body["recording_since"], body["since"] - 7 * 86400, "an earlier week to compare with")
        self.assertEqual(sum(body["answers"].values()), 5)
        self.assertEqual(body["filter"], "off")
        _, work, _ = self.request(ROUTE + "?bot=work")
        self.assertGreaterEqual(work["schedules"][0]["created_at"], work["since"], "a schedule made this week")
        self.assertTrue(work["schedules"][0]["paused"])

    def test_a_paused_schedule_shows_paused(self):
        self.assertEqual(self.request("/api/cron/jobs/morning-brief/pause?profile=default", "POST")[0], 200)
        _, body, _ = self.request(ROUTE + "?bot=default")
        self.assertTrue(body["schedules"][0]["paused"])

    def test_the_switch_turns_an_app_and_the_web_off_and_on_again(self):
        path = ROUTE + "/switch"
        status, answer, _ = self.request(path, "PUT", {"bot": "default", "kind": "app", "name": "notes", "on": False})
        self.assertEqual((status, answer), (200, {"bot": "default", "kind": "app", "name": "notes", "on": False}))
        self.assertFalse(self.request(ROUTE + "?bot=default")[1]["apps"][0]["on"])
        self.request(path, "PUT", {"bot": "default", "kind": "app", "name": "notes", "on": True})
        self.assertTrue(self.request(ROUTE + "?bot=default")[1]["apps"][0]["on"])
        self.request(path, "PUT", {"bot": "default", "kind": "web", "on": False})
        self.assertFalse(self.request(ROUTE + "?bot=default")[1]["web"]["on"])
        self.assertEqual(self.request(path, "PUT", {"bot": "default", "kind": "app", "name": "mail", "on": False})[0], 404)
        self.assertEqual(self.request(path, "PUT", {"bot": "default", "kind": "shell", "on": False})[0], 422)
        self.assertEqual(self.request(path, "GET")[0], 405)

    def test_private_bots_are_refused_and_other_scopes_too(self):
        for bot in ("moss", "private"):
            status, body, _ = self.request(f"{ROUTE}?bot={bot}")
            self.assertEqual((status, body["detail"]), (403, "The weekly note leaves private bots out."))
        self.assertEqual(self.request(ROUTE + "/switch", "PUT", {"bot": "moss", "kind": "web", "on": False})[0], 403)
        self.assertEqual(self.request(ROUTE + "?bot=default&profile=work")[0], 403)
        self.assertEqual(self.request(ROUTE + "?bot=../x")[0], 422)
        self.assertEqual(self.request(ROUTE + "?bot=nobody")[0], 404)

    def test_a_quiet_week_has_nothing_in_it(self):
        self.request("/api/_mock/week", "POST", {"state": "quiet"})
        _, body, _ = self.request(ROUTE + "?bot=default")
        self.assertEqual((body["places"], sum(body["answers"].values()), body["replies"]["left"]), ([], 0, 0))
        self.assertEqual(body["schedules"][0]["runs"], {"done": 0, "failed": 0, "unfinished": 0})

    def test_the_seed_keeps_vendor_names_out_with_neutral_models(self):
        mock.NEUTRAL_MODELS = True
        request = SimpleNamespace(path=ROUTE + "?bot=default", method="GET", body=b"{}", headers={})
        text = mock.process_request(None, request).body.decode()
        self.assertNotIn("Anthropic", text)
        self.assertNotIn("anthropic", text)


if __name__ == "__main__":
    unittest.main()
