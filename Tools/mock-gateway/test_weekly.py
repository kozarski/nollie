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
        "asks", "earlier_answers", "schedules", "runs_kept", "schedules_kept", "board", "apps", "web", "filter", "changes"}


class WeeklyFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        mock.NEUTRAL_MODELS = False
        self.jobs = copy.deepcopy(mock.CRON_JOBS)

    def tearDown(self):
        mock.PRIVATE_BOTS["profiles"] = None
        self.request("/api/_mock/week", "POST", {"state": "reset"})
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


    def test_remove_takes_the_app_out_and_keeps_it_as_a_change(self):
        path = ROUTE + "/remove-app"
        status, answer, _ = self.request(path, "POST", {"bot": "default", "name": "notes"})
        self.assertEqual((status, answer), (200, {"bot": "default", "name": "notes", "removed": True}))
        week = self.request(ROUTE + "?bot=default")[1]
        self.assertEqual(week["apps"], [])
        self.assertEqual([(c["kind"], c["name"]) for c in week["changes"]], [("app_removed", "notes")])
        self.assertEqual(self.request(path, "POST", {"bot": "default", "name": "notes"})[0], 404, "gone for good")
        self.assertEqual(self.request(path, "POST", {"bot": "default", "name": "../x"})[0], 422)
        self.assertEqual(self.request(path, "POST", {"bot": "moss", "name": "notes"})[0], 403)
        self.assertEqual(self.request(path, "GET")[0], 405)
        self.request("/api/_mock/week", "POST", {"state": "reset"})
        self.assertEqual(self.request(ROUTE + "?bot=default")[1]["changes"], [])

    def test_mutes_are_kept_for_every_device_and_never_for_a_private_bot(self):
        mutes = "/api/plugins/nollie-workflow/mutes"
        self.assertEqual(self.request(mutes)[1], {"muted": [], "saved": False})
        self.assertEqual(self.request(mutes + "/default", "PUT", {"muted": True})[1], {"muted": ["default"], "saved": True})
        self.request(mutes + "/work", "PUT", {"muted": True})
        self.request(mutes + "/default", "PUT", {"muted": False})
        self.assertEqual(self.request(mutes)[1]["muted"], ["work"])
        self.assertEqual(self.request(mutes + "/moss", "PUT", {"muted": True})[0], 403)
        self.assertEqual(self.request(mutes + "/work", "PUT", {"muted": "yes"})[0], 422)
        self.assertEqual(self.request(mutes + "/nobody", "PUT", {"muted": True})[0], 404)

    def test_the_notes_switch_and_day_and_the_mac_saying_it_sends_it(self):
        note = "/api/plugins/nollie-workflow/weekly-note"
        self.assertEqual(self.request(note)[1], {"on": True, "weekday": 1, "live_at": None, "saved": False})
        self.assertEqual(self.request(note, "PUT", {"on": False, "weekday": 6})[1]["weekday"], 6)
        self.assertEqual(self.request(note, "PUT", {"on": True, "weekday": 8})[0], 422)
        self.assertEqual(self.request(note, "PUT", {"on": 1, "weekday": 2})[0], 422)
        status, live, _ = self.request(note + "/live", "POST")
        self.assertEqual(status, 200)
        self.assertEqual(self.request(note)[1], {"on": False, "weekday": 6, "live_at": live["live_at"], "saved": True})


if __name__ == "__main__":
    unittest.main()
