import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from night_support import FakeJobs, job

try:
    import fastapi
    from fastapi.testclient import TestClient
except (ImportError, RuntimeError):
    fastapi = TestClient = None

BASE = "/api/plugins/nollie-workflow"


@unittest.skipUnless(fastapi and TestClient, "FastAPI and its test client are available in the Hermes runtime")
class NightRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("workflow_api_night_test",
                                                      Path(__file__).resolve().parents[1] / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)
        cls.rehearsals = __import__("nollie_workflow_dashboard.rehearsals", fromlist=["signature"])
        app = fastapi.FastAPI()
        app.include_router(cls.api.router, prefix=BASE)
        cls.client = TestClient(app)

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.root = self.home / "nollie-workflow"
        self.active = "default"
        profiles = SimpleNamespace(get_active_profile_name=lambda: self.active,
                                   get_profile_dir=lambda name: self.home if name == "default" else self.fail(name))
        modules = patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles})
        modules.start()
        self.addCleanup(modules.stop)
        held = job("new1", deliver="local", failure_deliver="local", enabled=False, state="paused")
        self.jobs = FakeJobs({"career": [held]})
        jobs = patch.object(self.api, "schedule_jobs", return_value=self.jobs)
        jobs.start()
        self.addCleanup(jobs.stop)
        self.now = int(time.time())
        self.store = self.api._posts.PostStore(self.root)
        self.post = {"id": "rehearsal-career-new1-e-81", "kind": "rehearsal", "at": self.now - 60, "bot": "career",
                     "bot_name": "Scout", "job_id": "new1", "title": "Morning prices", "schedule": "0 7 * * 1-5",
                     "state": "ready", "check": None, "outcome": "done", "held": [], "looked": [], "reply": ""}
        self.store.put(self.post)
        saved = {"deliver": "bot-chat", "failure_deliver": None}
        registry = self.rehearsals.empty(1)
        registry["jobs"]["career/new1"] = {
            "profile": "career", "job_id": "new1", "title": "Morning prices", "state": "ready", "kind": "rehearse",
            "signature": self.rehearsals.signature(held, self.jobs.file_hash("career"), saved), "saved": saved,
            "execution_id": "e-81", "post_id": self.post["id"], "updated_at": 1, "since": 1}
        self.rehearsals.write(self.root, registry)

    def test_posts_are_listed_oldest_first_without_caching(self):
        self.store.put({"id": "night-2026-10-21", "kind": "night_shift", "at": self.now - 30, "runs": [],
                        "unwatched": [], "counts": {}})
        response = self.client.get(BASE + "/posts")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        body = response.json()
        self.assertEqual(body["version"], 1)
        self.assertEqual([p["id"] for p in body["posts"]], [self.post["id"], "night-2026-10-21"])
        self.assertEqual([p["id"] for p in self.client.get(BASE + "/posts?limit=1").json()["posts"]],
                         ["night-2026-10-21"])
        self.assertEqual(self.client.get(BASE + f"/posts?since={self.now - 40}").json()["posts"][0]["id"],
                         "night-2026-10-21")

    def test_private_bots_never_appear(self):
        self.store.put({"id": "rehearsal-moss-x-1", "kind": "rehearsal", "at": self.now - 10, "bot": "moss"})
        self.store.put({"id": "night-x", "kind": "night_shift", "at": self.now - 5, "unwatched": ["moss"],
                        "runs": [{"id": "cron:a:b", "bot": "moss"}, {"id": "cron:c:d", "bot": "career"}]})
        body = self.client.get(BASE + "/posts").json()
        self.assertNotIn("rehearsal-moss-x-1", [p["id"] for p in body["posts"]])
        night_post = body["posts"][-1]
        self.assertEqual([r["bot"] for r in night_post["runs"]], ["career"])
        self.assertEqual(night_post["unwatched"], [])
        # A bot marked Private after a card was made is hidden in its text too.
        self.store.put({"id": "rehearsal-career-z-1", "kind": "rehearsal", "at": self.now - 1, "bot": "career",
                        "title": "Ask Moss", "held": [{"tool": "send_message", "target": "note for moss"}], "reply": "ok"})
        late = self.client.get(BASE + "/posts").json()["posts"][-1]
        self.assertEqual((late["title"], late["held"][0]["target"], late["held"][0]["tool"], late["reply"]),
                         ("[hidden]", "[hidden]", "send_message", "ok"))
        self.assertEqual(self.client.post(BASE + "/rehearsals/rehearsal-moss-x-1/turn-on").status_code, 404)

    def test_only_the_main_profile(self):
        self.active = "career"
        self.assertEqual(self.client.get(BASE + "/posts").status_code, 403)
        self.assertEqual(self.client.post(BASE + f"/rehearsals/{self.post['id']}/turn-on").status_code, 403)
        self.assertEqual(self.client.post(BASE + f"/rehearsals/{self.post['id']}/keep-off").status_code, 403)
        self.assertEqual(self.jobs.calls, [])

    def test_turn_on(self):
        response = self.client.post(BASE + f"/rehearsals/{self.post['id']}/turn-on")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(response.json()["state"], "on")
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "bot-chat")
        self.assertEqual(self.jobs.store["career"]["new1"]["state"], "scheduled")
        # A second tap: wrong state.
        again = self.client.post(BASE + f"/rehearsals/{self.post['id']}/turn-on")
        self.assertEqual(again.status_code, 409)
        self.assertEqual(again.json()["state"], "on")

    def test_a_changed_schedule_answers_409_with_the_card(self):
        self.jobs.store["career"]["new1"]["prompt"] = "Buy it now."
        response = self.client.post(BASE + f"/rehearsals/{self.post['id']}/turn-on")
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["state"], "changed")
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "local")

    def test_keep_off_and_unknown(self):
        response = self.client.post(BASE + f"/rehearsals/{self.post['id']}/keep-off")
        self.assertEqual((response.status_code, response.json()["state"]), (200, "kept_off"))
        self.assertEqual(self.client.post(BASE + "/rehearsals/nope/keep-off").status_code, 404)
        self.assertEqual(self.client.post(BASE + "/rehearsals/bad%20id/turn-on").status_code, 404)

    def test_card_answers_get_the_same_private_pass_as_the_list(self):
        self.store.update(self.post["id"], title="Ask Moss about prices", reply="Moss would know.")
        self.api._private.save(self.home, ["moss"])
        kept = self.client.post(BASE + f"/rehearsals/{self.post['id']}/keep-off")
        self.assertEqual(kept.status_code, 200)
        self.assertEqual((kept.json()["state"], kept.json()["title"], kept.json()["reply"]),
                         ("kept_off", "[hidden]", "[hidden]"))
        self.jobs.store["career"]["new1"]["prompt"] = "Buy it now."
        changed = self.client.post(BASE + f"/rehearsals/{self.post['id']}/turn-on")
        self.assertEqual(changed.status_code, 409)
        self.assertEqual((changed.json()["state"], changed.json()["title"]), ("changed", "[hidden]"))
        self.assertNotIn("Moss", changed.text)

    def test_moss_is_hidden_beside_a_saved_list(self):
        self.api._private.save(self.home, ["nowhere"])
        self.store.put({"id": "rehearsal-career-m-1", "kind": "rehearsal", "at": self.now - 10, "bot": "career",
                        "title": "Ask Moss", "held": [], "looked": [], "reply": "ok"})
        self.store.put({"id": "night-m", "kind": "night_shift", "at": self.now - 5, "unwatched": ["Moss", "Scout"],
                        "runs": [{"id": "cron:a:b", "bot": "career", "title": "Moss diary"}]})
        body = self.client.get(BASE + "/posts").json()
        rehearsal, night_post = body["posts"][-2:]
        self.assertEqual(rehearsal["title"], "[hidden]")
        self.assertEqual(night_post["unwatched"], ["Scout"])
        self.assertEqual(night_post["runs"][0]["title"], "[hidden]")
        self.assertNotIn("Moss", json.dumps(body))
        # A card answer gets the same pass.
        self.store.update(self.post["id"], title="Ask Moss about prices")
        kept = self.client.post(BASE + f"/rehearsals/{self.post['id']}/keep-off")
        self.assertEqual((kept.status_code, kept.json()["title"]), (200, "[hidden]"))

    def morning_card(self):
        def lines(bot, number, calls):
            run = f"cron:{bot}{number}:e-1"
            rows = [{"v": 1, "at": self.now - 900 + number, "run": run, "event": "start", "kind": "schedule",
                     "job_id": f"{bot}{number}", "title": "Check", "rehearsal": False}]
            for index in range(calls):
                rows.append({"v": 1, "at": self.now - 800 + index, "run": run, "event": "call", "call": str(index),
                             "tool": "terminal", "target": "df -h", "receipt": {"kind": "safe"}})
                rows.append({"v": 1, "at": self.now - 800 + index, "run": run, "event": "result",
                             "call": str(index), "tool": "terminal", "status": "done"})
            return rows
        bots = {"career": {"name": "Scout", "lines": lines("career", 1, 2), "jobs": [], "unrecorded": {"x": 1}},
                "nowhere": {"name": "Mason", "lines": lines("nowhere", 2, 3) + lines("nowhere", 3, 1), "jobs": [],
                            "unrecorded": {"y": 4}}}
        card = self.api._shift.night_card(day="2026-10-21", window=(self.now - 1000, self.now - 20), bots=bots,
                                          outcomes=[], grants=[], unwatched=[], private=frozenset())
        self.store.put(card)
        return card

    def test_counts_leave_out_a_bot_marked_private_later(self):
        card = self.morning_card()
        self.assertEqual(card["counts"], {"runs": 3, "actions": 6, "held": 0, "stopped": 0, "unrecorded": 5})
        shown = self.client.get(BASE + "/posts").json()["posts"][-1]
        self.assertNotIn("by_bot", shown)
        self.assertEqual(shown["counts"], card["counts"])
        self.api._private.save(self.home, ["nowhere"])
        shown = self.client.get(BASE + "/posts").json()["posts"][-1]
        self.assertEqual([r["bot"] for r in shown["runs"]], ["career"])
        self.assertEqual(shown["counts"], {"runs": 1, "actions": 2, "held": 0, "stopped": 0, "unrecorded": 1})
        self.assertNotIn("more_runs", shown)
        self.assertNotIn("note", shown)
        self.api._private.save(self.home, ["nowhere", "career"])
        shown = self.client.get(BASE + "/posts").json()["posts"][-1]
        self.assertEqual((shown["runs"], shown["counts"]["runs"], shown["note"]), ([], 0, self.api._shift.QUIET))

    def test_the_profile_named_private_is_left_out_whatever_the_list_says(self):
        self.api._private.save(self.home, ["moss"])
        self.store.put({"id": "rehearsal-private-x-1", "kind": "rehearsal", "at": self.now - 10, "bot": "private"})
        self.store.put({"id": "night-y", "kind": "night_shift", "at": self.now - 5, "unwatched": [],
                        "runs": [{"id": "cron:a:b", "bot": "private"}, {"id": "cron:c:d", "bot": "career"}]})
        body = self.client.get(BASE + "/posts").json()
        self.assertNotIn("rehearsal-private-x-1", [p["id"] for p in body["posts"]])
        self.assertEqual([r["bot"] for r in body["posts"][-1]["runs"]], ["career"])

    def test_a_damaged_registry_is_unavailable(self):
        (self.root / "rehearsals.json").write_text("{")
        self.assertEqual(self.client.post(BASE + f"/rehearsals/{self.post['id']}/turn-on").status_code, 503)


if __name__ == "__main__":
    unittest.main()
