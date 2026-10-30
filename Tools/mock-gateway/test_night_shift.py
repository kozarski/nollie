import copy
import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

try:
    import fastapi
    from fastapi.testclient import TestClient
except (ImportError, RuntimeError):
    fastapi = TestClient = None

spec = importlib.util.spec_from_file_location("night_shift_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

POSTS = "/api/plugins/nollie-workflow/posts"
REHEARSAL = "rehearsal-work-a41c7e-e-12"
NIGHT_KEYS = {"id", "kind", "at", "window", "counts", "unwatched", "runs", "sleep", "missed"}
RUN_KEYS = {"id", "kind", "bot", "bot_name", "title", "outcome", "started_at", "finished_at", "actions", "more", "due_at"}
MISSED_KEYS = {"bot", "bot_name", "job_id", "title", "first_due", "last_due", "count"}
ACTION_KEYS = {"tool", "target", "status", "at", "receipt"}
REHEARSAL_KEYS = {"id", "kind", "at", "bot", "bot_name", "job_id", "title", "schedule", "state", "check",
                  "outcome", "held", "looked", "reply"}
ADDON = Path(__file__).resolve().parents[2] / "Companions/nollie-workflow"


class NightShiftFixtureTests(unittest.TestCase):
    def setUp(self):
        self.posts = copy.deepcopy(mock.NIGHT_SHIFT["posts"])
        self.changed = set(mock.NIGHT_SHIFT["changed"])
        self.private = copy.deepcopy(mock.PRIVATE_BOTS)
        mock.PASSWORD_AUTH["enabled"] = False
        mock.LIVE.clear()

    def tearDown(self):
        mock.NIGHT_SHIFT["posts"] = self.posts
        mock.NIGHT_SHIFT["changed"] = self.changed
        mock.PRIVATE_BOTS.clear()
        mock.PRIVATE_BOTS.update(self.private)
        mock.LIVE.clear()

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def response(self, path, method="GET"):
        return mock.process_request(None, SimpleNamespace(path=path, method=method, body=b"{}", headers={}))

    def fetch(self, query=""):
        status, result = self.request(POSTS + query)
        self.assertEqual(status, 200)
        return result["posts"]

    def rehearsal(self):
        return next(post for post in self.fetch() if post["kind"] == "rehearsal")

    def test_posts_exist_before_any_reset_and_sit_after_the_seeded_chat(self):
        posts = self.fetch()
        self.assertEqual([post["kind"] for post in posts], ["night_shift", "rehearsal"])
        newest = mock.main_chat_newest()
        self.assertIsNotNone(newest)
        self.assertGreater(posts[0]["at"], newest)
        self.assertEqual(posts[1]["at"], posts[0]["at"] + 1)
        self.assertLessEqual(posts[1]["at"], time.time() + 5)

    def test_posts_have_exactly_the_documented_shape(self):
        status, result = self.request(POSTS)
        self.assertEqual(set(result), {"version", "posts"})
        self.assertEqual(result["version"], 1)
        night, rehearsal = result["posts"]
        self.assertEqual(set(night), NIGHT_KEYS)
        self.assertEqual(set(night["window"]), {"from", "to"})
        self.assertEqual(night["window"]["to"], night["at"])
        self.assertLess(night["window"]["from"], night["window"]["to"])
        self.assertEqual(night["counts"], {"runs": 2, "actions": 5, "held": 0, "stopped": 1, "unrecorded": 0})
        self.assertEqual(night["id"], "night-" + time.strftime("%Y-%m-%d", time.localtime(night["at"])))
        self.assertEqual(len(night["runs"]), 2)
        for run in night["runs"]:
            self.assertLessEqual(set(run) - {"late"}, RUN_KEYS)
            self.assertLessEqual(RUN_KEYS, set(run))
            self.assertTrue(night["window"]["from"] <= run["started_at"] < run["finished_at"] <= night["window"]["to"])
            for action in run["actions"]:
                self.assertEqual(set(action), ACTION_KEYS)
                self.assertTrue(run["started_at"] <= action["at"] <= run["finished_at"])
        receipts = [action["receipt"] for run in night["runs"] for action in run["actions"]]
        self.assertEqual(sorted(r["kind"] for r in receipts), ["allowlist", "always", "blocked", "safe", "tool"])
        always = next(r for r in receipts if r["kind"] == "always")
        self.assertEqual(set(always), {"kind", "detail", "granted_at"})
        self.assertLess(always["granted_at"], night["window"]["from"])
        self.assertIn({"kind": "blocked", "detail": "mac"}, receipts)
        blocked = next(a for run in night["runs"] for a in run["actions"] if a["receipt"]["kind"] == "blocked")
        self.assertEqual(blocked["status"], "blocked")

        # The Mac slept: one run waited until it woke, an hourly check missed three times, never counted as runs.
        (asleep,) = night["sleep"]
        self.assertEqual(set(asleep), {"from", "to", "kind"})
        self.assertEqual(asleep["kind"], "asleep")
        self.assertTrue(night["window"]["from"] <= asleep["from"] < asleep["to"] <= night["window"]["to"])
        late = [run for run in night["runs"] if run.get("late")]
        self.assertEqual([run["title"] for run in late], ["Morning brief"])
        self.assertTrue(asleep["from"] <= late[0]["due_at"] < asleep["to"] <= late[0]["started_at"])
        on_time = next(run for run in night["runs"] if not run.get("late"))
        self.assertLess(on_time["started_at"] - on_time["due_at"], 300)
        (missed,) = night["missed"]
        self.assertEqual(set(missed), MISSED_KEYS)
        self.assertEqual(missed["count"], 3)
        self.assertTrue(asleep["from"] <= missed["first_due"] < missed["last_due"] < asleep["to"])

        self.assertEqual(set(rehearsal), REHEARSAL_KEYS)
        self.assertEqual(rehearsal["id"], REHEARSAL)
        self.assertEqual((rehearsal["state"], rehearsal["check"], rehearsal["outcome"]), ("ready", None, "done"))
        self.assertEqual([len(rehearsal["held"]), len(rehearsal["looked"])], [2, 1])
        for item in rehearsal["held"] + rehearsal["looked"]:
            self.assertEqual(set(item), {"tool", "target", "at", "status", "receipt"})
        self.assertTrue(rehearsal["reply"])
        self.assertLessEqual(len(rehearsal["reply"]), 200)

    def test_bots_are_the_mocks_profiles_with_the_names_the_app_shows(self):
        night, rehearsal = self.fetch()
        bots = {(run["bot"], run["bot_name"]) for run in night["runs"]} | {(rehearsal["bot"], rehearsal["bot_name"])}
        self.assertEqual(bots, {("default", "Default"), ("work", "Work")})
        self.assertTrue({bot for bot, _ in bots} <= set(mock.PROFILES))

    def test_text_uses_neutral_names_only(self):
        text = json.dumps(self.fetch()).lower()
        for word in ("claude", "anthropic", "openai", "nous", "private", "moss", "\u2014"):
            self.assertNotIn(word, text)
        self.assertEqual(mock.neutral(text), text)

    def test_posts_answer_no_store_from_their_own_handler(self):
        response = self.response(POSTS)
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        # The catch-all would answer an empty 200; the posts come from the night shift handler.
        self.assertEqual(mock.rest(POSTS, {}), (200, {}))
        self.assertEqual(len(json.loads(response.body)["posts"]), 2)
        status, _ = self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on", "POST")
        self.assertEqual(status, 200)
        self.assertIsNone(mock.night_shift_rest("GET", "/api/plugins/nollie-workflow/private-bots", {}, {}))

    def test_the_switch_is_kept_and_a_reset_turns_it_on(self):
        path = "/api/plugins/nollie-workflow/night-shift"
        self.addCleanup(mock.NIGHT_SHIFT.update, on=True)
        self.assertEqual(self.request(path), (200, {"on": True, "damaged": False}))
        self.assertEqual(self.request(path, "PUT", {"on": False}), (200, {"on": False, "damaged": False, "saved": True}))
        self.assertEqual(self.request(path)[1]["on"], False)
        self.assertEqual(self.request(path, "PUT", {"on": "no"})[0], 422)
        self.assertEqual(self.request(path, "POST")[0], 405)
        self.assertEqual(self.request(path + "?profile=work")[0], 403)
        self.request("/api/_mock/night-shift", "POST")
        self.assertEqual(self.request(path)[1]["on"], True)

    def test_another_profile_is_refused(self):
        for path, method in ((POSTS + "?profile=work", "GET"),
                             (f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on?profile=work", "POST"),
                             (f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/keep-off?profile=work", "POST")):
            status, result = self.request(path, method)
            self.assertEqual(status, 403, path)
            self.assertIn("detail", result)
        self.assertEqual(self.rehearsal()["state"], "ready")
        self.assertEqual(len(self.fetch("?profile=default")), 2)

    def test_since_and_limit(self):
        night, rehearsal = self.fetch()
        self.assertEqual([p["id"] for p in self.fetch(f"?since={rehearsal['at']}")], [REHEARSAL])
        self.assertEqual(self.fetch(f"?since={rehearsal['at'] + 1}"), [])
        self.assertEqual([p["id"] for p in self.fetch("?limit=1")], [REHEARSAL])
        self.assertEqual([p["id"] for p in self.fetch(f"?since={night['at']}&limit=5")], [night["id"], REHEARSAL])
        for query in ("?since=soon", "?limit=0", "?limit=many"):
            self.assertEqual(self.request(POSTS + query)[0], 422, query)

    def test_old_posts_fall_outside_the_default_since(self):
        mock.NIGHT_SHIFT["posts"] = mock.night_shift_fixture(int(time.time()) - 15 * 24 * 3600)
        self.assertEqual(self.fetch(), [])
        self.assertEqual(len(self.fetch("?since=0")), 2)

    def test_reset_stamps_both_posts_after_a_newer_main_chat_row(self):
        live = mock.Session("rt-night", mock.COMPUTER_SESSION, "Disk cleanup on the log host", "default")
        newest = time.time() + 600.5
        live.store("user", "Anything overnight?", timestamp=newest - 30)
        live.store("assistant", "Here is what ran.", timestamp=newest)
        mock.LIVE[live.sid] = live
        self.assertEqual(mock.main_chat_newest(), newest)

        status, result = self.request("/api/_mock/night-shift", "POST")
        self.assertEqual(status, 200)
        night, rehearsal = result["posts"]
        self.assertEqual(night["at"], int(newest) + 1)
        self.assertEqual(rehearsal["at"], int(newest) + 2)
        self.assertGreater(night["at"], newest)
        self.assertEqual(self.fetch(), result["posts"])
        _, messages = self.request(f"/api/sessions/{mock.COMPUTER_SESSION}/messages")
        self.assertTrue(all(mock._row_seconds(m["timestamp"]) < night["at"] for m in messages["messages"]))

    def test_reset_without_newer_rows_uses_now(self):
        before = time.time()
        _, result = self.request("/api/_mock/night-shift", "POST")
        night, rehearsal = result["posts"]
        self.assertGreater(night["at"], before)
        self.assertGreater(night["at"], mock.main_chat_newest())
        self.assertLessEqual(rehearsal["at"], time.time() + 2)

    def test_reset_puts_an_answered_rehearsal_back_to_ready(self):
        self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on", "POST")
        self.request("/api/_mock/night-shift", "POST")
        self.assertEqual(self.rehearsal()["state"], "ready")

    def test_turn_on_answers_the_post_and_a_second_tap_is_a_conflict(self):
        path = f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on"
        status, post = self.request(path, "POST")
        self.assertEqual(status, 200)
        self.assertEqual(set(post), REHEARSAL_KEYS)
        self.assertEqual((post["id"], post["state"]), (REHEARSAL, "on"))
        self.assertEqual(self.rehearsal(), post)

        # A refused tap answers the card itself, as the add-on does, so the app can show where it stands.
        status, again = self.request(path, "POST")
        self.assertEqual(status, 409)
        self.assertEqual(again, post)
        status, refused = self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/keep-off", "POST")
        self.assertEqual((status, refused), (409, post))
        self.assertEqual(self.rehearsal()["state"], "on")

    def test_keep_off_then_turn_on_later(self):
        keep_off = f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/keep-off"
        status, post = self.request(keep_off, "POST")
        self.assertEqual((status, post["state"]), (200, "kept_off"))
        self.assertEqual(self.rehearsal()["state"], "kept_off")
        status, again = self.request(keep_off, "POST")
        self.assertEqual((status, again), (200, post))
        status, post = self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on", "POST")
        self.assertEqual((status, post["state"]), (200, "on"))

    def test_a_changed_schedule_answers_409_with_the_card_and_rehearses_again(self):
        status, result = self.request("/api/_mock/night-shift", "POST", {"changed": True})
        self.assertEqual(status, 200)
        self.assertEqual(result["posts"][1]["state"], "ready")
        turn_on = f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on"
        status, post = self.request(turn_on, "POST")
        self.assertEqual(status, 409)
        self.assertEqual(set(post), REHEARSAL_KEYS)
        self.assertEqual((post["id"], post["state"]), (REHEARSAL, "changed"))
        self.assertEqual(self.rehearsal(), post)
        for path in (turn_on, f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/keep-off"):
            self.assertEqual(self.request(path, "POST"), (409, post), path)
        # A plain reset brings back a card that turns on.
        self.request("/api/_mock/night-shift", "POST")
        self.assertEqual(self.request(turn_on, "POST")[1]["state"], "on")

    def test_keep_off_still_works_on_a_changed_schedule(self):
        self.request("/api/_mock/night-shift", "POST", {"changed": True})
        status, post = self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/keep-off", "POST")
        self.assertEqual((status, post["state"]), (200, "kept_off"))
        status, post = self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on", "POST")
        self.assertEqual((status, post["state"]), (409, "changed"))

    def test_unknown_ids_and_wrong_methods(self):
        night = self.fetch()[0]
        for post_id in ("rehearsal-work-000000-e-1", night["id"]):
            status, result = self.request(f"/api/plugins/nollie-workflow/rehearsals/{post_id}/turn-on", "POST")
            self.assertEqual(status, 404, post_id)
            self.assertIn("detail", result)
        self.assertEqual(self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on")[0], 405)
        self.assertEqual(self.request(POSTS, "POST")[0], 405)
        self.assertEqual(self.rehearsal()["state"], "ready")

    def test_a_bot_marked_private_leaves_the_cards(self):
        status, _ = self.request("/api/plugins/nollie-workflow/private-bots", "PUT", {"profiles": ["work"]})
        self.assertEqual(status, 200)
        posts = self.fetch()
        self.assertEqual([post["kind"] for post in posts], ["night_shift"])
        self.assertEqual({run["bot"] for run in posts[0]["runs"]}, {"default"})
        self.assertEqual(posts[0]["counts"], {"runs": 1, "actions": 3, "held": 0, "stopped": 0, "unrecorded": 0})
        self.assertEqual(self.request(f"/api/plugins/nollie-workflow/rehearsals/{REHEARSAL}/turn-on", "POST")[0], 404)
        self.assertNotIn("work", json.dumps(posts))


def shape(value):
    """Keys and value types, all the way down: what the app's decoder depends on."""
    if isinstance(value, dict):
        return {key: shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    return "number" if isinstance(value, (int, float)) and not isinstance(value, bool) else type(value).__name__


@unittest.skipUnless(fastapi and TestClient, "FastAPI and its test client are available")
class AddOnContractTests(unittest.TestCase):
    maxDiff = None
    """The mock against the real add-on: the same cards and the same answers to the same taps."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ADDON / "tests"))
        cls.addClassCleanup(sys.path.remove, str(ADDON / "tests"))
        from night_support import FakeJobs, job
        cls.FakeJobs, cls.job = FakeJobs, staticmethod(job)
        spec = importlib.util.spec_from_file_location("workflow_api_mock_contract", ADDON / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)
        cls.rehearsals = __import__("nollie_workflow_dashboard.rehearsals", fromlist=["signature"])
        app = fastapi.FastAPI()
        app.include_router(cls.api.router, prefix="/api/plugins/nollie-workflow")
        cls.client = TestClient(app)

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        profiles = SimpleNamespace(get_active_profile_name=lambda: "default", get_profile_dir=lambda name: self.home)
        modules = patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles})
        modules.start()
        self.addCleanup(modules.stop)
        self.held = self.job("a41c7e", name="Nightly export", deliver="local", failure_deliver="local",
                             enabled=False, state="paused",
                             schedule={"kind": "cron", "expr": "30 2 * * *", "display": "30 2 * * *"})
        # No display names, as the mock's profiles have none.
        self.jobs = self.FakeJobs({"work": [self.held]})
        jobs = patch.object(self.api, "schedule_jobs", return_value=self.jobs)
        jobs.start()
        self.addCleanup(jobs.stop)
        self.mock_state = (copy.deepcopy(mock.NIGHT_SHIFT["posts"]), set(mock.NIGHT_SHIFT["changed"]),
                           copy.deepcopy(mock.PRIVATE_BOTS))
        mock.PRIVATE_BOTS["profiles"] = None
        mock.PASSWORD_AUTH["enabled"] = False
        mock.LIVE.clear()
        self.addCleanup(self.restore_mock)

    def restore_mock(self):
        mock.NIGHT_SHIFT["posts"], mock.NIGHT_SHIFT["changed"], private = self.mock_state
        mock.PRIVATE_BOTS.clear()
        mock.PRIVATE_BOTS.update(private)
        mock.LIVE.clear()

    def lines(self, at, run="cron:a41c7e:e-12", job_id="a41c7e", rehearsal=False, due_at=None):
        """Receipt lines for one run, written as the recorder writes them."""
        line = lambda event, offset, **fields: {"run": run, "at": at + offset, "event": event, **fields}
        due = {} if due_at is None else {"due_at": due_at}
        return [
            line("start", 0, kind="schedule", job_id=job_id, execution_id="e-12", title="Nightly export",
                 rehearsal=rehearsal, **due),
            line("call", 10, call="c1", tool="read_file", target="/srv/export/last-run.log", receipt={"kind": "safe"}),
            line("result", 11, call="c1", tool="read_file", status="done"),
            line("call", 20, call="c2", tool="terminal", target="pg_dump --schema-only exports",
                 receipt={"kind": "allowlist", "detail": "pg_dump"}),
            line("result", 21, call="c2", tool="terminal", status="done"),
            line("call", 30, call="c3", tool="computer_use", target="screenshot", receipt={"kind": "blocked"}),
            line("result", 31, call="c3", tool="computer_use", status="blocked", block="mac"),
            line("call", 40, call="c4", tool="send_message", target="The export took 40 minutes tonight",
                 receipt={"kind": "held"}),
            line("result", 41, call="c4", tool="send_message", status="blocked", block="held"),
            line("reply", 50, text="The export finished but ran slow."),
            line("end", 60, outcome="done")]

    def real_rehearsal(self, at):
        shift, night = self.api._shift, self.api._night
        run = shift.assemble(self.lines(at - 100, rehearsal=True))["cron:a41c7e:e-12"]
        post = shift.rehearsal_post(profile="work", bot_name=night.bot_name(self.jobs, "work"), job=self.held,
                                    run=run, now=at, finished=True, private=set())
        self.api._posts.PostStore(self.home / "nollie-workflow").put(post)
        saved = {"deliver": "origin", "failure_deliver": None}
        registry = self.rehearsals.empty(1)
        registry["jobs"]["work/a41c7e"] = {
            "profile": "work", "job_id": "a41c7e", "title": "Nightly export", "state": "ready", "kind": "rehearse",
            "signature": self.rehearsals.signature(self.held, self.jobs.file_hash("work"), saved), "saved": saved,
            "execution_id": "e-12", "post_id": post["id"], "updated_at": at, "since": at}
        self.rehearsals.write(self.home / "nollie-workflow", registry)
        return post

    def real_night(self, at):
        shift, night = self.api._shift, self.api._night
        asleep = {"from": at - 7 * 3600, "to": at - 2 * 3600, "kind": "asleep"}
        # As the mock's: an on-time run before the Mac slept, opening with an allow-list command, then one that
        # waited for it to wake.
        bots = {bot: {"name": night.bot_name(self.jobs, bot), "jobs": [], "due": {},
                      "lines": self.lines(start, run=f"cron:{bot}-job:e-1", job_id=f"{bot}-job", due_at=due)}
                for bot, start, due in (("work", at - 8 * 3600, at - 8 * 3600), ("default", at - 3600, at - 6 * 3600))}
        bots["work"]["lines"] = [line for line in bots["work"]["lines"] if line.get("call") != "c1"]
        bots["work"]["jobs"] = [{"id": "hourly", "name": "Hourly price check"}]
        bots["work"]["due"] = {"hourly": [at - 6 * 3600, at - 5 * 3600, at - 4 * 3600]}
        card = shift.night_card(day="2026-10-21", window=(at - 12 * 3600, at), bots=bots, outcomes=[], grants=[],
                                unwatched=[], private=set(), sleep=[asleep])
        # As the routes send it: the per-bot counts stay in the store.
        return self.api.visible(card, set())

    def mock_posts(self, changed=False):
        status, result = self.mock_request("/api/_mock/night-shift", {"changed": changed})
        self.assertEqual(status, 200)
        return result["posts"]

    def mock_request(self, path, body=None):
        request = SimpleNamespace(path=path, method="POST", body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def taps(self, actions, changed=False):
        """Each tap's status, the state in the answer and the answer's keys, from the add-on and from the mock."""
        real_post, mock_post = self.real_rehearsal(int(time.time())), self.mock_posts(changed)[1]
        if changed:
            self.jobs.store["work"]["a41c7e"]["prompt"] = "Export everything twice."
        answers = {"add-on": [], "mock": []}
        for action in actions:
            for side, post in (("add-on", real_post), ("mock", mock_post)):
                path = f"/api/plugins/nollie-workflow/rehearsals/{post['id']}/{action}"
                if side == "add-on":
                    response = self.client.post(path)
                    status, body = response.status_code, response.json()
                else:
                    status, body = self.mock_request(path)
                answers[side].append((action, status, body.get("state"), sorted(body)))
        return answers

    def test_the_cards_have_the_add_ons_shape(self):
        at = int(time.time())
        night, rehearsal = self.mock_posts()
        self.assertEqual(shape(self.real_rehearsal(at)), shape(rehearsal))
        self.assertEqual(shape(self.real_night(at)), shape(night))
        receipts = lambda post: sorted(json.dumps(shape(a["receipt"]), sort_keys=True) + a["receipt"]["kind"]
                                       for run in post["runs"] for a in run["actions"])
        self.assertLessEqual(set(receipts(self.real_night(at))) - {'{"kind": "str"}held'}, set(receipts(night)))

    def test_the_bot_names_read_the_same_in_the_app(self):
        # The app shows an empty bot_name as the profile's name with a capital.
        shown = lambda item: item["bot_name"] or item["bot"][:1].upper() + item["bot"][1:]
        night, rehearsal = self.mock_posts()
        real = self.real_night(int(time.time()))
        self.assertEqual({r["bot"]: shown(r) for r in real["runs"]}, {r["bot"]: shown(r) for r in night["runs"]})
        self.assertEqual(shown(self.real_rehearsal(int(time.time()))), shown(rehearsal))

    def test_turn_on_then_taps_again(self):
        answers = self.taps(["turn-on", "turn-on", "keep-off"])
        self.assertEqual(answers["add-on"], answers["mock"])
        self.assertEqual([(status, state) for _, status, state, _ in answers["mock"]],
                         [(200, "on"), (409, "on"), (409, "on")])

    def test_keep_off_twice_then_turn_on(self):
        answers = self.taps(["keep-off", "keep-off", "turn-on"])
        self.assertEqual(answers["add-on"], answers["mock"])
        self.assertEqual([(status, state) for _, status, state, _ in answers["mock"]],
                         [(200, "kept_off"), (200, "kept_off"), (200, "on")])

    def test_a_changed_schedule(self):
        answers = self.taps(["turn-on", "turn-on", "keep-off"], changed=True)
        self.assertEqual(answers["add-on"], answers["mock"])
        self.assertEqual([(status, state) for _, status, state, _ in answers["mock"]],
                         [(409, "changed"), (409, "changed"), (409, "changed")])
        self.assertEqual(answers["mock"][0][3], sorted(REHEARSAL_KEYS))

    def test_keep_off_on_a_changed_schedule(self):
        answers = self.taps(["keep-off", "turn-on"], changed=True)
        self.assertEqual(answers["add-on"], answers["mock"])
        self.assertEqual([(status, state) for _, status, state, _ in answers["mock"]],
                         [(200, "kept_off"), (409, "changed")])


if __name__ == "__main__":
    unittest.main()
