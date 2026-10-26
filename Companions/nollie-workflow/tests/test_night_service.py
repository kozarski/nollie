from datetime import datetime
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from night_support import Clock, FakeJobs, job, load

service = load("night_service")
night = load("night_shift")
rehearsals = load("rehearsals")
posts = load("posts")
core = load("workflow_core")
receipts = load("receipts")
private_bots = load("private_bots")
route_signature = load("followup_policy").route_signature

MORNING = int(datetime(2026, 10, 21, 7, 30).timestamp())
PRIVATE = frozenset({"private", "moss"})


class ServiceCase(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.root = self.home / "nollie-workflow"
        self.clock = Clock(MORNING)
        self.jobs = FakeJobs({"default": [job("aaa111", name="Morning brief")],
                              "career": [job("3f2a9c")], "private": [job("secret1", name="Moss diary")]},
                             names={"default": "Nollie", "career": "Scout"},
                             scripts={("career", "prices.py"): "print('price')"})
        self.service = service.NightService(self.home, self.jobs, now=self.clock, private=lambda: PRIVATE,
                                            redactor=lambda text: text)
        for profile in ("default", "career"):
            core.atomic_write(self.root / "recorders" / (profile + ".json"), {"version": 1, "pid": 1, "at": 1})

    def settings(self, **changes):
        night.write_settings(self.root, **changes)

    def write(self, profile, lines):
        folder = self.root / "receipts" / profile
        folder.mkdir(parents=True, exist_ok=True)
        for line in lines:
            line = dict({"v": 1}, **line)
            with (folder / (night.local_day(line["at"]) + ".jsonl")).open("a") as handle:
                handle.write(json.dumps(line) + "\n")

    def registry(self):
        return rehearsals.read(self.root)

    def entry(self, profile="career", job_id="3f2a9c"):
        return self.registry()["jobs"][rehearsals.key(profile, job_id)]

    def started(self):
        """Rehearsals on, with today's schedules recorded as on."""
        self.settings(rehearsals=True)
        self.service.tick()
        self.jobs.calls.clear()


class SweepTests(ServiceCase):
    def test_turning_on_records_every_existing_job_as_on(self):
        self.started()
        registry = self.registry()
        self.assertEqual(registry["since"], night.read_settings(self.root)["rehearsals_since"])
        self.assertEqual(set(registry["jobs"]), {"default/aaa111", "career/3f2a9c"})
        self.assertTrue(all(e["state"] == "on" for e in registry["jobs"].values()))
        self.assertEqual(self.jobs.calls, [])
        self.service.tick()
        self.assertEqual(self.jobs.calls, [])

    def test_a_new_job_waits_with_its_delivery_saved_and_set_to_local(self):
        self.started()
        self.jobs.store["career"]["new1"] = job("new1", deliver="bot-chat", failure_deliver="telegram")
        self.service.tick()
        entry = self.entry(job_id="new1")
        self.assertEqual((entry["state"], entry["kind"]), ("waiting", "rehearse"))
        self.assertEqual(entry["saved"], {"deliver": "bot-chat", "failure_deliver": "telegram"})
        stored = self.jobs.store["career"]["new1"]
        self.assertEqual((stored["deliver"], stored["failure_deliver"], stored["enabled"]), ("local", "local", True))
        # The signature is the job as the person made it.
        self.assertEqual(entry["signature"], rehearsals.signature(
            job("new1", deliver="bot-chat", failure_deliver="telegram"), self.jobs.file_hash("career")))

    def test_an_edited_on_job_is_held_again(self):
        self.started()
        self.jobs.store["career"]["3f2a9c"]["prompt"] = "Buy the SSD."
        self.service.tick()
        self.assertEqual(self.entry()["state"], "waiting")
        self.assertEqual(self.jobs.store["career"]["3f2a9c"]["deliver"], "local")

    def test_a_job_nollie_cant_rehearse_is_paused_with_a_check_card(self):
        self.started()
        self.jobs.store["career"]["scr1"] = job("scr1", script="prices.py")
        self.jobs.store["career"]["once1"] = job("once1", schedule={"kind": "once", "run_at": "2026-10-22T07:00:00"})
        self.service.tick()
        for job_id, reason in (("scr1", "script"), ("once1", "once")):
            entry = self.entry(job_id=job_id)
            self.assertEqual((entry["state"], entry["kind"]), ("ready", "check"))
            self.assertEqual(self.jobs.store["career"][job_id]["state"], "paused")
            post = self.service.posts.get(entry["post_id"])
            self.assertEqual(post["check"]["reason"], reason)
            self.assertEqual((post["held"], post["looked"], post["reply"]), ([], [], ""))
        post = self.service.posts.get(self.entry(job_id="scr1")["post_id"])
        self.assertEqual(post["check"]["script"], "prices.py")
        self.assertEqual(len(post["check"]["hash"]), 12)
        self.assertEqual(post["check"]["prompt"], "Check the SSD price.")

    def test_an_unwatched_bot_keeps_new_jobs_paused(self):
        self.jobs.store["nowhere"] = {}
        self.started()
        self.jobs.store["nowhere"]["n1"] = job("n1")
        self.service.tick()
        entry = self.entry("nowhere", "n1")
        self.assertEqual(entry["state"], "ready")
        self.assertEqual(self.service.posts.get(entry["post_id"])["check"]["reason"], "unwatched")
        self.assertEqual(self.jobs.store["nowhere"]["n1"]["state"], "paused")

    def rehearse(self, *, end=True):
        self.started()
        made = MORNING - 30
        self.jobs.store["career"]["new1"] = job("new1", name="Morning prices",
                                                created_at=datetime.fromtimestamp(made).astimezone().isoformat())
        self.service.tick()
        run = "cron:new1:e-81"
        lines = [{"at": MORNING - 20, "run": run, "event": "start", "kind": "schedule", "job_id": "new1",
                  "execution_id": "e-81", "title": "Morning prices", "rehearsal": True},
                 {"at": MORNING - 19, "run": run, "event": "call", "call": "c1", "tool": "web_search",
                  "target": "2TB NVMe price", "receipt": {"kind": "tool"}},
                 {"at": MORNING - 18, "run": run, "event": "result", "call": "c1", "tool": "web_search", "status": "done"},
                 {"at": MORNING - 17, "run": run, "event": "call", "call": "c2", "tool": "send_message",
                  "target": "Price drop on the SSD", "receipt": {"kind": "held"}},
                 {"at": MORNING - 16, "run": run, "event": "result", "call": "c2", "tool": "send_message",
                  "status": "blocked", "block": "held"},
                 {"at": MORNING - 15, "run": run, "event": "reply", "text": "The 2TB drive is down to 119."}]
        if end:
            lines.append({"at": MORNING - 14, "run": run, "event": "end", "outcome": "done"})
        self.write("career", lines)
        self.clock.value += 15

    def test_a_finished_rehearsal_is_reported_and_paused(self):
        self.rehearse()
        self.service.tick()
        entry = self.entry(job_id="new1")
        self.assertEqual((entry["state"], entry["execution_id"]), ("ready", "e-81"))
        post = self.service.posts.get(entry["post_id"])
        self.assertEqual(post["id"], "rehearsal-career-new1-e-81")
        self.assertEqual((post["bot"], post["bot_name"], post["state"], post["outcome"]), ("career", "Scout", "ready", "done"))
        self.assertEqual(post["held"], [{"tool": "send_message", "target": "Price drop on the SSD", "at": MORNING - 17,
                                         "status": "blocked", "receipt": {"kind": "held"}}])
        self.assertEqual(post["looked"], [{"tool": "web_search", "target": "2TB NVMe price", "at": MORNING - 19,
                                           "status": "done", "receipt": {"kind": "tool"}}])
        self.assertEqual(post["reply"], "The 2TB drive is down to 119.")
        self.assertIn(("pause", "career", "new1", service.REHEARSED), self.jobs.calls)
        self.assertNotIn("note", post)

    def test_a_rehearsal_that_never_ended_is_reported_as_unfinished(self):
        self.rehearse(end=False)
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["state"], "waiting")  # Still running: wait.
        self.jobs.store["career"]["new1"]["last_run_at"] = datetime.fromtimestamp(MORNING).astimezone().isoformat()
        self.service.tick()
        post = self.service.posts.get(self.entry(job_id="new1")["post_id"])
        self.assertEqual((post["outcome"], post["note"]), ("failed", night.UNFINISHED))

    def test_a_held_job_that_ran_without_a_recorder_is_stopped(self):
        self.rehearse(end=False)
        (self.root / "receipts" / "career").rename(self.root / "elsewhere")
        self.jobs.store["career"]["new1"]["last_run_at"] = datetime.fromtimestamp(MORNING).astimezone().isoformat()
        self.service.tick()
        entry = self.entry(job_id="new1")
        self.assertEqual((entry["state"], entry["kind"]), ("ready", "check"))
        self.assertEqual(self.service.posts.get(entry["post_id"])["check"]["reason"], "unwatched")

    def test_turning_rehearsals_off_gives_waiting_jobs_their_delivery_back(self):
        self.started()
        self.jobs.store["career"]["new1"] = job("new1", deliver="bot-chat")
        self.jobs.store["career"]["scr1"] = job("scr1", script="prices.py")
        self.service.tick()
        self.settings(rehearsals=False)
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["state"], "on")
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "bot-chat")
        self.assertEqual(self.entry(job_id="scr1")["state"], "ready")
        self.assertEqual(self.jobs.store["career"]["scr1"]["state"], "paused")

    def watch(self, job_id, state="active"):
        followups = {"version": 1, "tasks": {"k1": {"board": "default", "task_id": "t1",
                                                    "watch": {"state": state, "job_id": job_id, "route": "r"}}}}
        core.atomic_write(self.root / "followups.json", followups)

    def test_a_board_follow_through_job_is_never_held(self):
        self.started()
        # Bound by a watch: its gate compares the delivery, so the sweep must leave it exactly as it is.
        self.jobs.store["default"]["watch1"] = job("watch1", script="nollie-followup-k1.py", precheck_fail_closed=True,
                                                   enabled=False, state="paused")
        self.jobs.store["default"]["watch2"] = job("watch2", deliver="local", enabled=False, state="paused")
        self.watch("watch1")
        followups = json.loads((self.root / "followups.json").read_text())
        followups["tasks"]["k2"] = {"board": "default", "task_id": "t2",
                                    "watch": {"state": "binding", "job_id": "watch2", "route": "r"}}
        core.atomic_write(self.root / "followups.json", followups)
        before = {k: dict(v) for k, v in self.jobs.store["default"].items()}
        self.service.tick()
        self.assertEqual(self.jobs.calls, [])
        self.assertEqual(self.jobs.store["default"], before)
        hasher = self.jobs.file_hash("default")
        for job_id in ("watch1", "watch2"):
            entry = self.entry("default", job_id)
            self.assertEqual(entry["state"], "on")
            self.assertEqual(rehearsals.decide("default", self.jobs.store["default"][job_id], hasher, self.registry(),
                                               None), rehearsals.REAL)
        self.assertIsNone(self.service.posts.get("check-default-watch1-" + self.entry("default", "watch1")["signature"][:8]))
        # A stopped watch is an ordinary schedule again; an unchanged one stays on.
        self.watch("watch1", state="stopped")
        self.service.tick()
        self.assertEqual(self.entry("default", "watch1")["state"], "on")
        self.assertEqual(self.jobs.calls, [])

    def test_a_paused_job_bound_moments_later_keeps_its_route(self):
        self.started()
        # Board follow-through makes its job paused, then binds it: a hold in between would bind "local".
        made = job("watch3", script="nollie-followup-k3.py", precheck_fail_closed=True, enabled=False,
                   state="paused")
        self.jobs.store["default"]["watch3"] = made
        self.service.tick()
        self.assertNotIn("default/watch3", self.registry()["jobs"])
        self.assertEqual(self.jobs.calls, [])
        followups = {"version": 1, "tasks": {"k3": {"board": "default", "task_id": "t3", "watch": {
            "state": "active", "job_id": "watch3", "route": route_signature(made), "script": made["script"]}}}}
        core.atomic_write(self.root / "followups.json", followups)
        self.service.tick()
        stored = self.jobs.store["default"]["watch3"]
        self.assertEqual((stored["deliver"], stored["failure_deliver"]), ("bot-chat", None))
        self.assertEqual(self.entry("default", "watch3")["state"], "on")
        self.assertEqual(self.jobs.calls, [])
        self.assertEqual(rehearsals.decide("default", stored, self.jobs.file_hash("default"), self.registry(),
                                           followups), rehearsals.REAL)

    def test_a_paused_job_is_held_once_it_is_resumed(self):
        self.started()
        self.jobs.store["career"]["new1"] = job("new1", enabled=False, state="paused")
        self.service.tick()
        self.assertNotIn("career/new1", self.registry()["jobs"])
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "bot-chat")
        self.jobs.resume("career", "new1")
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["state"], "waiting")
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "local")

    def test_a_ready_job_given_a_new_delivery_is_held_again(self):
        self.rehearse()
        self.service.tick()
        first = self.entry(job_id="new1")
        self.assertEqual((first["state"], first["kind"]), ("ready", "rehearse"))
        self.jobs.store["career"]["new1"]["deliver"] = "telegram"
        on_disk = []
        real = self.jobs.update

        def update(profile, job_id, updates):
            # The new delivery is saved before Hermes is changed.
            on_disk.append(self.entry(job_id="new1"))
            return real(profile, job_id, updates)
        with patch.object(self.jobs, "update", side_effect=update):
            self.service.tick()
        self.assertEqual([(e["state"], e["saved"]["deliver"]) for e in on_disk], [("waiting", "telegram")])
        entry = self.entry(job_id="new1")
        self.assertEqual((entry["state"], entry["kind"]), ("waiting", "rehearse"))
        self.assertEqual(entry["saved"], {"deliver": "telegram", "failure_deliver": None})
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "local")
        self.assertEqual(self.service.posts.get(first["post_id"])["state"], "changed")

    def test_a_job_with_the_same_id_in_another_bot_is_still_held(self):
        self.started()
        self.watch("new1")
        self.jobs.store["career"]["new1"] = job("new1")
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["state"], "waiting")

    def test_an_unreadable_follow_through_file_leaves_the_main_bot_alone(self):
        self.started()
        (self.root / "followups.json").write_text("{")
        self.jobs.store["default"]["new0"] = job("new0")
        self.jobs.store["career"]["new1"] = job("new1")
        self.service.tick()
        self.assertNotIn("default/new0", self.registry()["jobs"])
        self.assertEqual(self.jobs.store["default"]["new0"]["deliver"], "bot-chat")
        self.assertEqual(self.entry(job_id="new1")["state"], "waiting")

    def test_the_saved_delivery_reaches_disk_before_hermes_changes_it(self):
        self.started()
        self.jobs.store["career"]["new1"] = job("new1", deliver="bot-chat", failure_deliver="telegram")
        real = rehearsals.write
        writes = []

        def write_then_stop(root, document):
            writes.append(json.loads(json.dumps(document)))
            if len(writes) > 1:
                raise OSError("the gateway stopped")
            real(root, document)
        with patch.object(service.rehearsals, "write", side_effect=write_then_stop):
            with self.assertRaises(OSError):
                self.service.tick()
        # The first write came before the update; the job is already local in Hermes.
        self.assertEqual(writes[0]["jobs"]["career/new1"]["saved"], {"deliver": "bot-chat", "failure_deliver": "telegram"})
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "local")
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["saved"], {"deliver": "bot-chat", "failure_deliver": "telegram"})
        # Turning rehearsals off gives it back what the person set.
        self.settings(rehearsals=False)
        self.service.tick()
        stored = self.jobs.store["career"]["new1"]
        self.assertEqual((stored["deliver"], stored["failure_deliver"]), ("bot-chat", "telegram"))

    def test_a_check_job_whose_hold_was_cut_short_is_paused_on_the_next_tick(self):
        self.started()
        self.jobs.store["career"]["scr1"] = job("scr1", script="prices.py")
        with patch.object(self.jobs, "pause", side_effect=OSError("stopped")):
            self.service.tick()
        entry = self.entry(job_id="scr1")
        self.assertEqual((entry["state"], entry["kind"]), ("waiting", "check"))
        self.assertEqual(self.jobs.store["career"]["scr1"]["state"], "scheduled")
        self.service.tick()
        entry = self.entry(job_id="scr1")
        self.assertEqual((entry["state"], entry["kind"]), ("ready", "check"))
        self.assertEqual(self.jobs.store["career"]["scr1"]["state"], "paused")
        self.assertEqual(entry["saved"], {"deliver": "bot-chat", "failure_deliver": None})
        self.assertEqual(self.service.posts.get(entry["post_id"])["check"]["reason"], "script")

    def test_a_bot_whose_schedules_cant_be_read_is_recorded_later(self):
        self.jobs.fail_list.add("career")
        self.settings(rehearsals=True)
        self.service.tick()
        self.service.note()
        registry = self.registry()
        # The others are recorded at once, so rehearsals work for them.
        self.assertEqual(registry["since"], night.read_settings(self.root)["rehearsals_since"])
        self.assertEqual(registry["pending"], ["career"])
        self.assertEqual(set(registry["jobs"]), {"default/aaa111"})
        status = json.loads((self.root / service.STATUS_NAME).read_text())
        self.assertEqual(status["last_error"], "OSError")
        # A new job of a recorded bot is held meanwhile.
        self.jobs.store["default"]["new0"] = job("new0")
        self.service.tick()
        self.assertEqual(self.entry("default", "new0")["state"], "waiting")
        self.jobs.fail_list.clear()
        self.service.tick()
        self.service.note()
        registry = self.registry()
        self.assertNotIn("pending", registry)
        self.assertEqual(registry["jobs"]["career/3f2a9c"]["state"], "on")
        self.assertEqual(self.jobs.store["career"]["3f2a9c"]["deliver"], "bot-chat")
        self.assertIsNone(json.loads((self.root / service.STATUS_NAME).read_text())["last_error"])

    def test_a_bot_whose_add_on_was_removed_or_disabled_is_not_watched(self):
        self.started()
        self.jobs.uninstalled.add("career")  # Its old heartbeat file is still there.
        self.jobs.store["career"]["new1"] = job("new1")
        self.service.tick()
        entry = self.entry(job_id="new1")
        self.assertEqual((entry["state"], entry["kind"]), ("ready", "check"))
        self.assertEqual(self.service.posts.get(entry["post_id"])["check"]["reason"], "unwatched")
        self.assertEqual(self.jobs.store["career"]["new1"]["state"], "paused")

    def test_the_profile_named_private_is_never_read_whatever_the_list_says(self):
        self.service.private = lambda: frozenset({"moss"})
        self.write("private", [{"at": MORNING - 60, "run": "r", "event": "end", "outcome": "done"}])
        core.atomic_write(self.root / "recorders" / "private.json", {"version": 1, "pid": 1, "at": 1})
        self.settings(rehearsals=True, night_shift=True)
        self.service.tick()
        self.service.tick()
        self.jobs.store["private"]["new9"] = job("new9")
        self.service.tick()
        registry = self.registry()
        self.assertFalse([name for name in registry["jobs"] if name.startswith("private/")])
        self.assertNotIn("pending", registry)
        self.assertFalse([call for call in self.jobs.calls if call[1] == "private"])
        self.assertNotIn("Moss diary", json.dumps(self.service.posts.all()))
        self.assertFalse((self.root / "receipts" / "private").exists())
        self.assertFalse((self.root / "recorders" / "private.json").exists())

    def test_the_carried_over_names_count_beside_a_saved_list(self):
        private_bots.save(self.home, ["nowhere"])
        self.service = service.NightService(self.home, self.jobs, now=self.clock, redactor=lambda text: text)
        self.started()
        self.jobs.store["career"]["scr1"] = job("scr1", name="Moss diary", prompt="Ask moss first.",
                                                script="prices.py")
        self.service.tick()
        post = self.service.posts.get(self.entry(job_id="scr1")["post_id"])
        self.assertEqual((post["title"], post["check"]["prompt"]), (night.HIDDEN, night.HIDDEN))
        shown = json.dumps(self.service.posts.all())
        self.assertNotIn("Moss diary", shown)
        self.assertNotIn("moss first", shown)

    def test_a_damaged_registry_is_kept_for_repair(self):
        self.started()
        (self.root / rehearsals.FILE_NAME).write_text("{")
        with self.assertRaises(ValueError):
            self.service.tick()
        self.assertEqual((self.root / rehearsals.FILE_NAME).read_text(), "{")


class CardActionTests(ServiceCase):
    def setUp(self):
        super().setUp()
        SweepTests.rehearse(self)
        self.service.tick()
        self.post_id = self.entry(job_id="new1")["post_id"]
        self.jobs.calls.clear()

    def turn_on(self):
        return service.turn_on(self.home, self.post_id, self.jobs, now=self.clock)

    def test_turn_on_restores_delivery_and_resumes(self):
        post = self.turn_on()
        self.assertEqual(post["state"], "on")
        stored = self.jobs.store["career"]["new1"]
        self.assertEqual((stored["deliver"], stored["failure_deliver"], stored["state"]), ("bot-chat", None, "scheduled"))
        self.assertEqual(self.entry(job_id="new1")["state"], "on")
        self.assertEqual(self.service.posts.get(self.post_id)["state"], "on")
        # The next sweep sees it as on and leaves it alone.
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["state"], "on")
        self.assertEqual([c for c in self.jobs.calls if c[0] != "resume" and c[0] != "update"], [])
        # A second tap is the wrong state.
        with self.assertRaises(service.Conflict):
            self.turn_on()

    def test_a_changed_schedule_rehearses_again(self):
        self.jobs.store["career"]["new1"]["prompt"] = "Buy it now."
        with self.assertRaises(service.Conflict) as raised:
            self.turn_on()
        self.assertEqual(raised.exception.post["state"], "changed")
        entry = self.entry(job_id="new1")
        self.assertEqual(entry["state"], "waiting")
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "local")
        self.assertIn(("resume", "career", "new1"), self.jobs.calls)
        # The sweep keeps it as it is until its rehearsal.
        self.service.tick()
        self.assertEqual(self.entry(job_id="new1")["state"], "waiting")

    def test_a_changed_delivery_is_held_before_the_schedule_resumes(self):
        stored = self.jobs.store["career"]["new1"]
        stored.update(prompt="Buy it now.", deliver="telegram", failure_deliver="bot-chat")
        with self.assertRaises(service.Conflict):
            self.turn_on()
        updates = [c for c in self.jobs.calls if c[0] == "update"]
        self.assertEqual(updates, [("update", "career", "new1", {"deliver": "local", "failure_deliver": "local"})])
        self.assertLess(self.jobs.calls.index(updates[0]), self.jobs.calls.index(("resume", "career", "new1")))
        entry = self.entry(job_id="new1")
        self.assertEqual(entry["saved"], {"deliver": "telegram", "failure_deliver": "bot-chat"})
        self.assertEqual(entry["signature"], rehearsals.signature(
            dict(stored, deliver="telegram", failure_deliver="bot-chat"), self.jobs.file_hash("career")))
        self.assertEqual((stored["deliver"], stored["failure_deliver"]), ("local", "local"))

    def test_a_change_that_needs_a_look_first_is_not_resumed(self):
        self.jobs.store["career"]["new1"]["script"] = "prices.py"
        with self.assertRaises(service.Conflict):
            self.turn_on()
        self.assertNotIn(("resume", "career", "new1"), self.jobs.calls)
        self.service.tick()
        entry = self.entry(job_id="new1")
        self.assertEqual((entry["state"], entry["kind"]), ("ready", "check"))
        self.assertEqual(self.service.posts.get(entry["post_id"])["check"]["reason"], "script")
        self.assertEqual(self.jobs.store["career"]["new1"]["state"], "paused")

    def test_a_failed_resume_leaves_the_card_to_try_again(self):
        with patch.object(self.jobs, "resume", side_effect=OSError("store busy")):
            with self.assertRaises(RuntimeError):
                self.turn_on()
        self.assertEqual(self.entry(job_id="new1")["state"], "ready")
        stored = self.jobs.store["career"]["new1"]
        self.assertEqual((stored["deliver"], stored["state"]), ("local", "paused"))
        self.assertEqual(self.service.posts.get(self.post_id)["state"], "ready")
        with patch.object(self.jobs, "resume", return_value=None):
            with self.assertRaises(RuntimeError):
                self.turn_on()
        self.assertEqual(self.entry(job_id="new1")["state"], "ready")
        self.assertEqual(self.turn_on()["state"], "on")
        self.assertEqual(self.jobs.store["career"]["new1"]["deliver"], "bot-chat")

    def test_keep_off(self):
        post = service.keep_off(self.home, self.post_id, self.jobs, now=self.clock)
        self.assertEqual(post["state"], "kept_off")
        self.assertEqual(self.entry(job_id="new1")["state"], "kept_off")
        self.assertEqual(self.jobs.store["career"]["new1"]["state"], "paused")
        # Kept off can still be turned on later.
        self.assertEqual(self.turn_on()["state"], "on")
        with self.assertRaises(service.Conflict):
            service.keep_off(self.home, self.post_id, self.jobs, now=self.clock)

    def test_unknown_cards(self):
        for action in (service.turn_on, service.keep_off):
            with self.assertRaises(LookupError):
                action(self.home, "rehearsal-career-nope-e-1", self.jobs, now=self.clock)

    def test_a_one_off_whose_time_passed(self):
        registry = self.registry()
        registry["jobs"]["career/new1"]["kind"] = "check"
        rehearsals.write(self.root, registry)
        value = self.jobs.store["career"]["new1"]
        value["schedule"] = {"kind": "once", "run_at": "2026-10-20T07:00:00+00:00"}
        registry["jobs"]["career/new1"]["signature"] = rehearsals.signature(
            value, self.jobs.file_hash("career"), registry["jobs"]["career/new1"]["saved"])
        rehearsals.write(self.root, registry)
        with self.assertRaises(service.Conflict):
            self.turn_on()
        self.assertEqual(self.entry(job_id="new1")["state"], "ready")


class RehearsalReportTests(unittest.TestCase):
    def report(self, lines):
        run = night.assemble([dict({"v": 1, "run": "cron:new1:e-81"}, **line) for line in lines])["cron:new1:e-81"]
        return night.rehearsal_post(profile="career", bot_name="Scout", job=job("new1"), run=run, now=MORNING,
                                    finished=True, private=frozenset())

    def test_calls_are_sorted_by_what_stopped_them(self):
        post = self.report([
            {"at": 1, "event": "start", "kind": "schedule", "job_id": "new1", "execution_id": "e-81", "rehearsal": True},
            # A look that ran and failed still ran.
            {"at": 2, "event": "call", "call": "1", "tool": "web_extract", "target": "news.example.com/a",
             "receipt": {"kind": "tool"}},
            {"at": 3, "event": "result", "call": "1", "tool": "web_extract", "status": "failed"},
            # A look with no result line also ran.
            {"at": 4, "event": "call", "call": "2", "tool": "read_file", "target": "/tmp/a.md", "receipt": {"kind": "tool"}},
            # Stopped at the Mac: never done, and never something a real run could do either.
            {"at": 5, "event": "call", "call": "3", "tool": "computer_use", "target": "click",
             "receipt": {"kind": "blocked", "detail": "mac"}},
            {"at": 6, "event": "result", "call": "3", "tool": "computer_use", "status": "blocked", "block": "mac"},
            # Held, with its result line lost.
            {"at": 7, "event": "call", "call": "4", "tool": "send_message", "target": "Hello", "receipt": {"kind": "held"}},
            {"at": 8, "event": "end", "outcome": "done"}])
        self.assertEqual([(a["tool"], a["status"], a["receipt"]) for a in post["looked"]],
                         [("web_extract", "failed", {"kind": "tool"}), ("read_file", "failed", {"kind": "tool"})])
        self.assertEqual([(a["tool"], a["status"], a["receipt"]) for a in post["held"]],
                         [("computer_use", "blocked", {"kind": "blocked", "detail": "mac"}),
                          ("send_message", "blocked", {"kind": "held"})])


    def test_ask_firsts_hold_keeps_its_reason(self):
        target = "Run this command:\nrm -rf build\nWhy Nollie asks: rm deletes files."
        post = self.report([
            {"at": 1, "event": "start", "kind": "schedule", "job_id": "new1", "execution_id": "e-81", "rehearsal": True},
            # Its result line lost: the receipt alone says it was held.
            {"at": 2, "event": "call", "call": "1", "tool": "terminal", "target": target,
             "receipt": {"kind": "held", "detail": "ask_first"}},
            {"at": 3, "event": "call", "call": "2", "tool": "send_message", "target": "Send: send message",
             "receipt": {"kind": "held", "detail": "ask_first"}},
            {"at": 4, "event": "result", "call": "2", "tool": "send_message", "status": "blocked",
             "block": "ask_first"},
            {"at": 5, "event": "end", "outcome": "done"}])
        self.assertEqual([(a["tool"], a["status"], a["receipt"]) for a in post["held"]],
                         [("terminal", "blocked", {"kind": "held", "detail": "ask_first"}),
                          ("send_message", "blocked", {"kind": "held", "detail": "ask_first"})])
        self.assertEqual(post["held"][0]["target"], target)
        self.assertEqual(post["looked"], [])


class MorningCardTests(ServiceCase):
    def card(self):
        return self.service.posts.get("night-" + datetime.fromtimestamp(self.clock.value).date().isoformat())

    def test_quiet_night(self):
        self.settings(night_shift=True)
        self.service.tick()
        card = self.card()
        self.assertEqual(card["counts"], {"runs": 0, "actions": 0, "held": 0, "stopped": 0, "unrecorded": 0})
        self.assertEqual(card["note"], night.QUIET)
        self.assertEqual(card["window"], {"from": MORNING - 43200, "to": MORNING})
        self.assertEqual(card["unwatched"], [])

    def test_an_always_answer_is_not_a_run(self):
        self.settings(night_shift=True)
        self.write("default", [{"at": MORNING - 600, "run": "approval", "event": "always", "keys": ["git push"],
                                "detail": "git push"}])
        self.service.tick()
        card = self.card()
        self.assertEqual((card["runs"], card["counts"]["runs"], card["note"]), ([], 0, night.QUIET))
        # It still says when Always was chosen.
        self.assertEqual([g["keys"] for g in night.GrantLog(self.root).read()], [["git push"]])

    def test_titles_from_schedules_and_the_board_are_scrubbed(self):
        self.settings(night_shift=True)
        token = "sk-abcdefghijklmnopqrstuvwx1234"
        self.jobs.store["default"]["aaa111"]["name"] = "Deploy with " + token
        self.jobs.store["career"]["3f2a9c"]["name"] = "Prices " + token
        self.jobs.store["career"]["3f2a9c"]["last_run_at"] = datetime.fromtimestamp(MORNING - 100).astimezone().isoformat()
        self.write("default", [{"at": MORNING - 300, "run": "cron:aaa111:e-1", "event": "start", "kind": "schedule",
                                "job_id": "aaa111", "rehearsal": False}])
        night.OutcomeLog(self.root).add({"board": "default", "task": {"id": "t1", "title": "Use " + token,
                                                                      "assignee": "career"},
                                         "event": {"id": 1, "created_at": MORNING - 200}}, "completed")
        self.assertNotIn(token, (self.root / "outcomes.json").read_text())
        self.service.tick()
        text = json.dumps(self.card())
        self.assertNotIn(token, text)
        self.assertEqual([r["title"] for r in self.card()["runs"]],
                         ["Deploy with [hidden]", "Use [hidden]", "Prices [hidden]"])

    def test_a_bot_with_no_display_name_reads_as_the_app_shows_it(self):
        self.settings(night_shift=True)
        self.jobs.store["work"] = {}
        self.service.tick()
        self.assertEqual(self.card()["unwatched"], ["Work"])
        self.assertEqual(service.bot_name(self.jobs, "default"), "Nollie")  # Its display name.
        self.jobs.names.pop("default")
        self.assertEqual(service.bot_name(self.jobs, "default"), "Default")

    def test_not_before_the_morning_hour_and_once_a_day(self):
        self.settings(night_shift=True, morning_hour=8)
        self.service.tick()
        self.assertIsNone(self.card())
        self.settings(night_shift=True, morning_hour=7)
        self.service.tick()
        first = self.card()
        self.clock.value += 600
        self.service.tick()
        self.assertEqual(self.card(), first)

    def test_the_window_starts_where_the_last_card_ended_and_is_at_most_a_day(self):
        self.settings(night_shift=True)
        self.service.posts.put({"id": "night-old", "kind": "night_shift", "at": MORNING - 90000,
                                "window": {"from": MORNING - 100000, "to": MORNING - 90000}})
        self.service.tick()
        self.assertEqual(self.card()["window"]["from"], MORNING - 86400)
        self.clock.value += 86400
        self.service.tick()
        self.assertEqual(self.card()["window"], {"from": MORNING, "to": MORNING + 86400})

    def test_runs_receipts_board_outcomes_and_gated_runs(self):
        self.settings(night_shift=True)
        run = "cron:aaa111:e-80"
        start = MORNING - 3600
        self.write("default", [
            {"at": start - 86400 * 2, "run": "approval", "event": "always", "keys": ["git push"], "detail": "git push"},
            {"at": start, "run": run, "event": "start", "kind": "schedule", "job_id": "aaa111", "execution_id": "e-80",
             "title": "Morning brief", "rehearsal": False},
            {"at": start + 1, "run": run, "event": "call", "call": "1", "tool": "terminal", "target": "df -h",
             "receipt": {"kind": "safe"}},
            {"at": start + 2, "run": run, "event": "result", "call": "1", "tool": "terminal", "status": "done"},
            {"at": start + 3, "run": run, "event": "call", "call": "2", "tool": "terminal",
             "target": "git push origin main", "receipt": {"kind": "always", "detail": "git push", "key": "git push"}},
            {"at": start + 4, "run": run, "event": "result", "call": "2", "tool": "terminal", "status": "done"},
            {"at": start + 5, "run": run, "event": "call", "call": "3", "tool": "computer_use", "target": "click",
             "receipt": {"kind": "blocked", "detail": "mac"}},
            {"at": start + 6, "run": run, "event": "result", "call": "3", "tool": "computer_use", "status": "blocked",
             "block": "mac"},
            {"at": start + 7, "run": run, "event": "call", "call": "4", "tool": "read_file",
             "target": "/Users/someone/Agents/moss/notes.md", "receipt": {"kind": "tool"}},
            {"at": start + 8, "run": run, "event": "result", "call": "4", "tool": "read_file", "status": "done"},
            {"at": start + 68, "run": run, "event": "end", "outcome": "done"}])
        self.write("moss", [{"at": start, "run": "cron:x:y", "event": "start", "kind": "schedule", "job_id": "x",
                             "title": "Diary", "rehearsal": False}])
        self.jobs.store["career"]["3f2a9c"]["last_run_at"] = datetime.fromtimestamp(start + 100).astimezone().isoformat()
        night.OutcomeLog(self.root).merge([
            {"board": "default", "task_id": "t1", "title": "Draft the report", "assignee": "career",
             "outcome": "completed", "at": start + 200, "event_id": 4},
            {"board": "moss-board", "task_id": "t2", "title": "Diary", "assignee": "career",
             "outcome": "completed", "at": start + 300, "event_id": 5}])
        self.write("career", [{"at": start + 150, "run": "board:t1", "event": "start", "kind": "board", "task": "t1",
                               "rehearsal": False},
                              {"at": start + 160, "run": "board:t1", "event": "call", "call": "9", "tool": "write_file",
                               "target": "/tmp/report.md", "receipt": {"kind": "tool"}},
                              {"at": start + 161, "run": "board:t1", "event": "result", "call": "9",
                               "tool": "write_file", "status": "done"}])
        self.service.tick()
        card = self.card()
        self.assertEqual([(r["id"], r["kind"], r["outcome"]) for r in card["runs"]],
                         [("cron:aaa111:e-80", "schedule", "done"),
                          (f"cron:3f2a9c:{start + 100}", "schedule", "skipped"),
                          ("board:t1", "board", "done")])
        brief = card["runs"][0]
        self.assertEqual((brief["bot"], brief["bot_name"], brief["title"]), ("default", "Nollie", "Morning brief"))
        self.assertEqual((brief["started_at"], brief["finished_at"]), (start, start + 68))
        receipts_seen = [a["receipt"] for a in brief["actions"]]
        self.assertEqual(receipts_seen, [{"kind": "safe"},
                                         {"kind": "always", "detail": "git push", "granted_at": start - 86400 * 2},
                                         {"kind": "blocked", "detail": "mac"}, {"kind": "tool"}])
        self.assertEqual(brief["actions"][3]["target"], "[hidden]")
        self.assertEqual(card["runs"][2]["title"], "Draft the report")
        self.assertEqual(card["runs"][2]["actions"][0]["target"], "/tmp/report.md")
        self.assertEqual(card["counts"], {"runs": 3, "actions": 5, "held": 0, "stopped": 1, "unrecorded": 0})
        self.assertNotIn("Diary", json.dumps(card))
        self.assertNotIn("moss", json.dumps(card).replace("[hidden]", ""))

    def test_a_call_held_for_the_persons_yes_is_counted_as_held(self):
        self.settings(night_shift=True)
        run, start = "cron:aaa111:e-80", MORNING - 3600
        self.write("default", [
            {"at": start, "run": run, "event": "start", "kind": "schedule", "job_id": "aaa111", "execution_id": "e-80",
             "title": "Morning brief", "rehearsal": False},
            {"at": start + 1, "run": run, "event": "call", "call": "1", "tool": "terminal",
             "target": "Run this command:\nrm -rf build", "receipt": {"kind": "held", "detail": "ask_first"}},
            {"at": start + 2, "run": run, "event": "result", "call": "1", "tool": "terminal", "status": "blocked",
             "block": "ask_first"},
            {"at": start + 3, "run": run, "event": "call", "call": "2", "tool": "terminal", "target": "df -h",
             "receipt": {"kind": "safe"}},
            {"at": start + 4, "run": run, "event": "result", "call": "2", "tool": "terminal", "status": "done"},
            {"at": start + 5, "run": run, "event": "end", "outcome": "done"}])
        self.service.tick()
        card = self.card()
        [brief] = [r for r in card["runs"] if r["id"] == run]
        held = brief["actions"][0]
        self.assertEqual((held["status"], held["receipt"]), ("blocked", {"kind": "held", "detail": "ask_first"}))
        self.assertEqual(held["target"], "Run this command:\nrm -rf build")
        self.assertEqual(card["counts"]["held"], 1)
        self.assertEqual(card["counts"]["stopped"], 0)

    def test_a_call_ask_first_held_reads_held_even_without_its_result_line(self):
        line = {"at": 5, "event": "call", "call": "1", "tool": "send_message", "target": "Send: send message",
                "receipt": {"kind": "held", "detail": "ask_first"}}
        found = night.action({"line": line, "result": None}, "default", {}, frozenset())
        self.assertEqual((found["status"], found["receipt"]), ("blocked", {"kind": "held", "detail": "ask_first"}))
        # On the morning card of a real run too: held, not failed.
        self.settings(night_shift=True)
        run, start = "cron:aaa111:e-82", MORNING - 3600
        self.write("default", [
            {"at": start, "run": run, "event": "start", "kind": "schedule", "job_id": "aaa111", "execution_id": "e-82",
             "title": "Morning brief", "rehearsal": False},
            dict(line, at=start + 1, run=run),
            {"at": start + 2, "run": run, "event": "end", "outcome": "done"}])
        self.service.tick()
        card = self.card()
        [brief] = [r for r in card["runs"] if r["id"] == run]
        self.assertEqual((brief["actions"][0]["status"], brief["actions"][0]["receipt"]),
                         ("blocked", {"kind": "held", "detail": "ask_first"}))
        self.assertEqual((card["counts"]["held"], card["counts"]["stopped"]), (1, 0))

    def test_the_card_keeps_each_stops_rule_and_what_a_hold_needs_a_yes_for(self):
        self.settings(night_shift=True)
        run, start = "cron:aaa111:e-83", MORNING - 3600
        self.write("default", [
            {"at": start, "run": run, "event": "start", "kind": "schedule", "job_id": "aaa111", "execution_id": "e-83",
             "title": "Morning brief", "rehearsal": False},
            {"at": start + 1, "run": run, "event": "call", "call": "1", "tool": "terminal", "target": "rm -rf build",
             "receipt": {"kind": "blocked", "detail": "risky", "rule": "recursive delete"}},
            {"at": start + 2, "run": run, "event": "result", "call": "1", "tool": "terminal", "status": "blocked",
             "block": "risky"},
            {"at": start + 3, "run": run, "event": "call", "call": "2", "tool": "send_message",
             "target": "Send: send message", "receipt": {"kind": "held", "detail": "ask_first", "ask": "send"}},
            {"at": start + 4, "run": run, "event": "result", "call": "2", "tool": "send_message", "status": "blocked",
             "block": "ask_first"},
            # A rule that names a private bot is hidden whole; an unknown hold kind is dropped.
            {"at": start + 5, "run": run, "event": "call", "call": "3", "tool": "terminal", "target": "cat x",
             "receipt": {"kind": "blocked", "detail": "deny_rule", "rule": "cat *moss*", "ask": "launch"}},
            {"at": start + 6, "run": run, "event": "result", "call": "3", "tool": "terminal", "status": "blocked",
             "block": "deny_rule"},
            # Stopped by something other than what was predicted: the predicted rule's words are not kept.
            {"at": start + 7, "run": run, "event": "call", "call": "4", "tool": "terminal", "target": "rm -r old",
             "receipt": {"kind": "blocked", "detail": "risky", "rule": "recursive delete"}},
            {"at": start + 8, "run": run, "event": "result", "call": "4", "tool": "terminal", "status": "blocked",
             "block": "hardline"},
            {"at": start + 9, "run": run, "event": "end", "outcome": "done"}])
        self.service.tick()
        [brief] = [r for r in self.card()["runs"] if r["id"] == run]
        self.assertEqual([a["receipt"] for a in brief["actions"]], [
            {"kind": "blocked", "detail": "risky", "rule": "recursive delete"},
            {"kind": "held", "detail": "ask_first", "ask": "send"},
            {"kind": "blocked", "detail": "deny_rule", "rule": "[hidden]"},
            {"kind": "blocked", "detail": "hardline"}])

    def test_receipts_from_before_reasons_were_kept_read_as_they_did(self):
        # A line written by the 1.0 recorder: no rule, no hold kind. Nothing is made up for it.
        line = {"at": 5, "event": "call", "call": "1", "tool": "terminal", "target": "rm -rf build",
                "receipt": {"kind": "blocked", "detail": "risky"}}
        result = {"at": 6, "event": "result", "call": "1", "tool": "terminal", "status": "blocked", "block": "risky"}
        found = night.action({"line": line, "result": result}, "default", [], frozenset())
        self.assertEqual(found["receipt"], {"kind": "blocked", "detail": "risky"})
        line = dict(line, receipt={"kind": "always", "detail": "git push", "key": "git push"})
        found = night.action({"line": line, "result": dict(result, status="done", block=None)}, "default", [],
                             frozenset())
        self.assertEqual(found["receipt"], {"kind": "always", "detail": "git push"})

    def test_caps(self):
        self.settings(night_shift=True)
        run = "cron:aaa111:e-1"
        lines = [{"at": MORNING - 500, "run": run, "event": "start", "kind": "schedule", "job_id": "aaa111",
                  "rehearsal": False, "title": "Morning brief"}]
        for index in range(45):
            lines.append({"at": MORNING - 400 + index, "run": run, "event": "call", "call": str(index),
                          "tool": "terminal", "target": f"echo {index}", "receipt": {"kind": "safe"}})
        self.write("default", lines)
        self.service.tick()
        brief = self.card()["runs"][0]
        self.assertEqual((len(brief["actions"]), brief["more"]), (40, 5))
        self.assertEqual(self.card()["counts"]["actions"], 45)

    def test_one_card_holds_a_bounded_number_of_actions(self):
        self.settings(night_shift=True)
        lines = []
        for number in range(8):
            run = f"cron:aaa111:e-{number}"
            lines.append({"at": MORNING - 5000 + number * 100, "run": run, "event": "start", "kind": "schedule",
                          "job_id": "aaa111", "rehearsal": False, "title": "Morning brief"})
            for index in range(40):
                lines.append({"at": MORNING - 5000 + number * 100 + 1, "run": run, "event": "call",
                              "call": str(index), "tool": "terminal", "target": "x" * 300, "receipt": {"kind": "safe"}})
        self.write("default", lines)
        self.service.tick()
        card = self.card()
        shown = sum(len(r["actions"]) for r in card["runs"])
        self.assertEqual(shown, night.MAX_CARD_ACTIONS)
        self.assertEqual(shown + sum(r["more"] for r in card["runs"]), 320)
        self.assertEqual(card["counts"]["actions"], 320)

    def test_unwatched_bots_are_named(self):
        self.settings(night_shift=True)
        self.jobs.store["nowhere"] = {}
        self.jobs.names["nowhere"] = "Mason"
        self.service.tick()
        self.assertEqual(self.card()["unwatched"], ["Mason"])


class HousekeepingTests(ServiceCase):
    def test_old_days_and_private_bots_are_deleted(self):
        old = MORNING - 15 * 86400
        recent = MORNING - 3 * 86400
        self.write("career", [{"at": old, "run": "r", "event": "end", "outcome": "done"},
                              {"at": recent, "run": "r", "event": "end", "outcome": "done"}])
        self.write("moss", [{"at": recent, "run": "r", "event": "end", "outcome": "done"}])
        core.atomic_write(self.root / "recorders" / "moss.json", {"version": 1, "pid": 1, "at": 1})
        self.service.tick()
        names = sorted(p.name for p in (self.root / "receipts" / "career").iterdir())
        self.assertEqual(names, [night.local_day(recent) + ".jsonl"])
        self.assertFalse((self.root / "receipts" / "moss").exists())
        self.assertFalse((self.root / "recorders" / "moss.json").exists())

    def test_always_answers_outlive_the_day_files(self):
        self.write("career", [{"at": MORNING - 13 * 86400, "run": "approval", "event": "always",
                               "keys": ["git push"], "detail": "git push"}])
        self.service.tick()
        self.clock.value += 2 * 86400
        self.service.housekept = None
        self.service.tick()
        self.assertEqual([g["keys"] for g in night.GrantLog(self.root).read()], [["git push"]])
        self.assertEqual(list((self.root / "receipts" / "career").iterdir()), [])

    def test_a_damaged_private_list_stops_everything(self):
        self.service.private = lambda: (_ for _ in ()).throw(ValueError("damaged"))
        self.settings(night_shift=True, rehearsals=True)
        self.service.tick()
        self.assertFalse((self.root / "posts.json").exists())
        self.assertFalse((self.root / rehearsals.FILE_NAME).exists())


class PostStoreTests(unittest.TestCase):
    def test_bounds_and_replacement(self):
        with TemporaryDirectory() as temporary:
            clock = Clock(MORNING)
            store = posts.PostStore(Path(temporary), now=clock)
            store.put({"id": "old", "kind": "night_shift", "at": MORNING - 31 * 86400})
            store.put({"id": "a", "kind": "rehearsal", "at": MORNING - 10})
            store.put({"id": "a", "kind": "rehearsal", "at": MORNING - 5, "state": "on"})
            self.assertEqual([p["id"] for p in store.all()], ["a"])
            self.assertEqual(store.get("a")["state"], "on")
            for index in range(posts.MAX_POSTS + 5):
                store.put({"id": f"n{index}", "kind": "night_shift", "at": MORNING - 1000 + index})
            self.assertEqual(len(store.all()), posts.MAX_POSTS)
            self.assertEqual([p["id"] for p in store.since(MORNING - 600, 2)], ["n404", "a"])
            with self.assertRaises(ValueError):
                store.put({"id": "x", "kind": "other", "at": 1})

    def test_a_store_over_its_size_drops_the_oldest_and_keeps_working(self):
        with TemporaryDirectory() as temporary, patch.object(posts, "MAX_BYTES", 20_000), \
                patch.object(posts, "REPAIR_BYTES", 80_000), patch.object(posts, "MAX_POST_BYTES", 5_000):
            root = Path(temporary)
            store = posts.PostStore(root, now=Clock(MORNING))
            big = [{"id": f"p{index}", "kind": "night_shift", "at": MORNING - 1000 + index, "note": "x" * 1000}
                   for index in range(30)]
            # Written by an older build, already over the bound: reading fails, writing repairs it.
            core.atomic_write(root / posts.FILE_NAME, {"version": 1, "posts": big})
            with self.assertRaises(ValueError):
                store.all()
            store.put({"id": "new", "kind": "rehearsal", "at": MORNING, "state": "ready"})
            self.assertLessEqual((root / posts.FILE_NAME).stat().st_size, 20_000)
            kept = [p["id"] for p in store.all()]
            self.assertEqual(kept[-1], "new")
            self.assertNotIn("p0", kept)
            self.assertIn("p29", kept)
            self.assertEqual(store.update("new", state="on")["state"], "on")
            with self.assertRaises(ValueError):
                store.put({"id": "huge", "kind": "night_shift", "at": MORNING, "note": "x" * 6_000})


class OutcomeLogTests(unittest.TestCase):
    def test_engine_feeds_followed_outcomes_once_and_bounded(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = night.OutcomeLog(root)
            record = {"board": "default", "task": {"id": "t1", "title": "Draft", "assignee": "career"},
                      "event": {"id": 1, "created_at": 100}}
            self.assertTrue(log.add(record, "completed"))
            self.assertFalse(log.add(record, "completed"))
            self.assertFalse(log.add(record, "review_requested"))
            for index in range(night.OUTCOME_LIMIT + 3):
                log.add(dict(record, event={"id": index + 10, "created_at": 200 + index}), "blocked")
            items = log.read()
            self.assertEqual(len(items), night.OUTCOME_LIMIT)
            self.assertEqual(items[-1]["at"], 200 + night.OUTCOME_LIMIT + 2)

    def test_engine_calls_the_log_and_survives_its_failure(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = core.initial_state(100)
            state["enabled"] = True
            core.atomic_write(root / "state.json", state)
            bots = core.Bots(("default", "career"), ())
            event = {"board": "default", "task": {"id": "t1", "title": "Draft", "assignee": "career",
                     "created_by": "default", "tenant": None, "status": "done", "session_id": None, "block_kind": None},
                     "event": {"id": 3, "kind": "completed", "run_id": 1, "created_at": 150, "payload": {}}}

            class Source:
                def bots(self):
                    return bots

                def read(self, cursors, since):
                    return {"events": [event], "cursors": {}}

                def validate(self, record):
                    return True

            class Delivery:
                def enqueue(self, key, content):
                    return {"status": "queued"}

            seen = []
            core.Engine(root, Source(), Delivery(), now=lambda: 200,
                        outcome_log=lambda record, kind: seen.append(kind)).tick()
            self.assertEqual(seen, ["completed"])

            def broken(record, kind):
                raise OSError("disk")
            state = core.read_state(root)
            state["outbox"] = {}
            core.atomic_write(root / "state.json", state)
            core.Engine(root, Source(), Delivery(), now=lambda: 200, outcome_log=broken).tick()
            self.assertEqual(len(core.read_state(root)["outbox"]), 1)


if __name__ == "__main__":
    unittest.main()
