import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from night_support import Checks, Clock, FakeJobs, execution, job, load

recorder = load("recorder")
receipts = load("receipts")
rehearsals = load("rehearsals")
night = load("night_shift")
route_signature = load("followup_policy").route_signature

AT = 1792560000
# A rehearsal holds this, but Ask first lets it through: it writes a file, so it is not look-only.
WRITE = {"path": "/tmp/a", "content": "x"}


class Untouchable:
    def get(self):
        raise AssertionError("settings were read for a chat the person is in")


class RecorderCase(unittest.TestCase):
    profile = "career"

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.root = self.home / "nollie-workflow"
        self.run_now = None
        self.env, self.session = {}, {}
        self.private = frozenset()
        self.jobs = FakeJobs({self.profile: [job()]})
        self.clock = Clock(AT)

    def make(self, *, checks=None, toolset=lambda name: None, settings=None):
        def cron():
            if isinstance(self.run_now, Exception):
                raise self.run_now
            return self.run_now
        rec = recorder.Recorder(root=self.root, profile=self.profile, main_home=self.home, cron=cron,
                                session_env=lambda name: self.session.get(name, ""), environ=self.env,
                                checks=checks or Checks(), toolset=toolset, jobs=self.jobs, settings=settings,
                                private=lambda: self.private, clock=self.clock, monotonic=self.clock)
        rec.writer = recorder.Writer(self.root, self.profile, private=rec.is_private, start=False)
        return rec

    def turn_on(self, **changes):
        night.write_settings(self.root, **dict({"night_shift": True, "rehearsals": False}, **changes))

    def lines(self, rec):
        rec.writer.drain()
        path = self.root / "receipts" / self.profile / (night.local_day(AT) + ".jsonl")
        if not path.exists():
            return []
        return [json.loads(row) for row in path.read_text().splitlines()]

    def registry(self, entries, since=None):
        registry = rehearsals.empty(since)
        for entry in entries:
            registry["jobs"][rehearsals.key(entry["profile"], entry["job_id"])] = entry
        rehearsals.write(self.root, registry)

    def on_entry(self, value=None, profile=None):
        value = value or job()
        profile = profile or self.profile
        return {"profile": profile, "job_id": value["id"], "title": value["name"], "state": "on",
                "signature": rehearsals.signature(value, self.jobs.file_hash(profile)), "kind": "rehearse",
                "saved": None, "execution_id": None, "post_id": None, "updated_at": AT, "since": AT}


class AttendedTests(RecorderCase):
    def test_a_chat_the_person_is_in_touches_nothing(self):
        rec = self.make(settings=Untouchable())
        for result in (rec.guard(tool_name="computer_use", args={}, task_id="t", session_id="s"),
                       rec.record_call(tool_name="terminal", args={"command": "open x"}, session_id="s"),
                       rec.record_result(tool_name="terminal", result="{}", status="ok", session_id="s"),
                       rec.session_start(session_id="s"), rec.session_end(session_id="s", completed=True),
                       rec.transform_reply(response_text="hello", session_id="s"),
                       rec.llm_reply(session_id="s", assistant_response="hello")):
            self.assertIsNone(result)
        self.assertFalse(self.root.exists())
        self.assertTrue(rec.writer.queue.empty())

    def test_unattended_runs_and_their_keys(self):
        rec = self.make()
        self.run_now = execution()
        self.assertEqual(rec.identify("cron:3f2a9c:e-81", "s")["key"], "cron:3f2a9c:e-81")
        self.assertEqual(rec.identify("other", "s")["key"], "cron:3f2a9c:e-81")
        self.run_now = None
        self.env["HERMES_KANBAN_TASK"] = "t_42"
        self.assertEqual(rec.identify("x", "s"), {"key": "board:t_42", "kind": "board", "task": "t_42"})
        del self.env["HERMES_KANBAN_TASK"]
        self.session["HERMES_CRON_SESSION"] = "1"
        self.assertEqual(rec.identify("x", "child"), {"key": "helper:child", "kind": "helper"})
        self.session.clear()
        self.run_now = RuntimeError("no cron identity")
        self.assertIsNone(rec.identify("x", "s"))

    def test_both_features_off_means_no_guard_and_no_receipts(self):
        rec = self.make()
        self.run_now = execution()
        self.assertIsNone(rec.guard(tool_name="computer_use", args={}, session_id="s"))
        rec.record_call(tool_name="terminal", args={"command": "df -h"}, session_id="s")
        self.assertEqual(self.lines(rec), [])


class GuardTests(RecorderCase):
    def test_unattended_runs_never_use_the_mac_or_touch_the_add_on(self):
        self.turn_on()
        rec = self.make(toolset=lambda name: "mcp-cua-recorder" if name == "record_screen" else None)
        for setup in (lambda: setattr(self, "run_now", execution()),
                      lambda: self.env.update(HERMES_KANBAN_TASK="t1"),
                      lambda: self.session.update(HERMES_CRON_SESSION="1")):
            self.run_now = None
            self.env.clear()
            self.session.clear()
            setup()
            for tool, args in (("computer_use", {"action": "click"}), ("record_screen", {}),
                               ("mcp__nollie_mac__open_app", {}), ("terminal", {"command": "osascript -e 1"})):
                self.assertEqual(rec.guard(tool_name=tool, args=args, session_id="s"),
                                 {"action": "block", "message": receipts.MAC}, tool)
            self.assertEqual(rec.guard(tool_name="write_file", args={"path": "/x/nollie-workflow/a.py"},
                                       session_id="s"), {"action": "block", "message": receipts.PLUGIN})
            self.assertIsNone(rec.guard(tool_name="mcp__cua__space_bash", args={}, session_id="s"))
            self.assertIsNone(rec.guard(tool_name="terminal", args={"command": "df -h"}, session_id="s"))

    def test_a_failing_toolset_lookup_blocks(self):
        self.turn_on()
        def broken(name):
            raise RuntimeError("registry")
        rec = self.make(toolset=broken)
        self.run_now = execution()
        self.assertEqual(rec.guard(tool_name="read_file", args={}, session_id="s")["action"], "block")

    def test_fails_closed_only_where_it_blocks(self):
        self.turn_on(rehearsals=True)
        self.registry([self.on_entry()], since=night.read_settings(self.root)["rehearsals_since"])
        rec = self.make()
        class Unreadable:
            def get(self, profile, job_id):
                raise OSError("the cron store is locked")
        rec.jobs = Unreadable()  # The job can't be read: the decision rehearses.
        self.run_now = execution()
        self.assertEqual(rec.guard(tool_name="write_file", args=WRITE, session_id="s")["message"], receipts.REHEARSAL)
        self.assertIsNone(rec.guard(tool_name="read_file", args={"path": "/a"}, session_id="s"))
        # Anything else that goes wrong lets the call through.
        rec.verdict = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("unexpected"))
        self.assertIsNone(rec.guard(tool_name="write_file", args=WRITE, session_id="s"))

    def test_damaged_settings_turn_protection_on(self):
        self.root.mkdir(parents=True)
        (self.root / night.SETTINGS_NAME).write_text("{")
        rec = self.make()
        self.run_now = execution()
        self.assertEqual(rec.guard(tool_name="computer_use", args={}, session_id="s")["action"], "block")
        self.assertEqual(rec.guard(tool_name="write_file", args=WRITE, session_id="s")["message"], receipts.REHEARSAL)


class DecisionTests(RecorderCase):
    def decide(self, rec, execution_id="e-1"):
        self.run_now = execution(execution_id=execution_id)
        return rec.guard(tool_name="write_file", args=WRITE, session_id="s")

    def test_an_on_job_that_matches_runs_for_real(self):
        self.turn_on(rehearsals=True)
        self.registry([self.on_entry()], since=night.read_settings(self.root)["rehearsals_since"])
        self.assertIsNone(self.decide(self.make()))

    def test_a_changed_or_unknown_job_rehearses(self):
        self.turn_on(rehearsals=True)
        since = night.read_settings(self.root)["rehearsals_since"]
        self.registry([self.on_entry()], since=since)
        self.jobs.store[self.profile]["3f2a9c"]["prompt"] = "Buy the SSD."
        self.assertEqual(self.decide(self.make())["message"], receipts.REHEARSAL)
        self.registry([], since=since)
        self.assertEqual(self.decide(self.make(), "e-2")["message"], receipts.REHEARSAL)

    def test_a_ready_or_kept_off_job_someone_resumed_rehearses(self):
        self.turn_on(rehearsals=True)
        since = night.read_settings(self.root)["rehearsals_since"]
        for state in ("ready", "kept_off", "waiting"):
            self.registry([dict(self.on_entry(), state=state)], since=since)
            self.assertEqual(self.decide(self.make(), state)["message"], receipts.REHEARSAL, state)

    def test_the_decision_is_made_once_per_execution(self):
        self.turn_on(rehearsals=True)
        self.registry([], since=night.read_settings(self.root)["rehearsals_since"])
        rec = self.make()
        self.assertEqual(self.decide(rec)["message"], receipts.REHEARSAL)
        self.registry([self.on_entry()], since=night.read_settings(self.root)["rehearsals_since"])
        self.assertEqual(self.decide(rec)["message"], receipts.REHEARSAL)
        self.assertIsNone(self.decide(rec, "e-2"))

    def test_a_bound_follow_through_check_runs_for_real(self):
        self.profile = "default"
        watched = job("aa11", script="nollie-followup-k.py", precheck_fail_closed=True)
        self.jobs = FakeJobs({"default": [watched]})
        self.turn_on(rehearsals=True)
        self.registry([], since=night.read_settings(self.root)["rehearsals_since"])
        watch = {"state": "active", "job_id": "aa11", "route": route_signature(watched), "script": watched["script"]}
        load("workflow_core").atomic_write(self.root / "followups.json", {"version": 1, "tasks": {"k": {"watch": watch}}})
        self.run_now = execution("aa11")
        self.assertIsNone(self.make().guard(tool_name="write_file", args=WRITE, session_id="s"))
        # A different route or script is not the bound check.
        for change in ({"route": "other"}, {"script": "other.py"}, {"state": "stopped"}):
            load("workflow_core").atomic_write(self.root / "followups.json",
                                               {"version": 1, "tasks": {"k": {"watch": dict(watch, **change)}}})
            self.assertEqual(self.make().guard(tool_name="write_file", args=WRITE, session_id="s")["action"], "block")

    def test_a_damaged_registry_uses_the_last_good_copy(self):
        self.turn_on(rehearsals=True)
        since = night.read_settings(self.root)["rehearsals_since"]
        self.registry([self.on_entry()], since=since)
        rec = self.make()
        self.assertIsNone(self.decide(rec, "e-1"))
        (self.root / rehearsals.FILE_NAME).write_text("{damaged")
        self.assertIsNone(self.decide(rec, "e-2"))
        self.jobs.store[self.profile]["new1"] = job("new1")
        self.run_now = execution("new1", "e-3")
        self.assertEqual(rec.guard(tool_name="write_file", args=WRITE, session_id="s")["message"], receipts.REHEARSAL)

    def test_a_damaged_registry_without_a_good_copy_rehearses_everything(self):
        self.turn_on(rehearsals=True)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / rehearsals.FILE_NAME).write_text("[]")
        self.assertEqual(self.decide(self.make())["message"], receipts.REHEARSAL)

    def test_just_turned_on_runs_for_real_until_the_service_records_todays_jobs(self):
        self.turn_on(rehearsals=True)
        self.assertIsNone(self.decide(self.make()))

    def test_rehearsals_off_means_real_runs(self):
        self.turn_on(rehearsals=False)
        self.registry([])
        self.assertIsNone(self.decide(self.make()))


class RehearsalRunTests(RecorderCase):
    def setUp(self):
        super().setUp()
        self.turn_on(rehearsals=True)
        self.registry([], since=night.read_settings(self.root)["rehearsals_since"])
        self.run_now = execution()
        self.rec = self.make()
        self.rec.session_start(session_id="s")

    def test_look_only_calls_run_and_the_rest_are_held(self):
        guard = lambda tool, args: self.rec.guard(tool_name=tool, args=args, task_id="cron:3f2a9c:e-81", session_id="s")
        self.assertIsNone(guard("read_file", {"path": "/a"}))
        self.assertIsNone(guard("web_extract", {"urls": ["https://a.example/b"]}))
        self.assertEqual(guard("web_extract", {"urls": ["https://a.example/b?q=1"]})["message"], receipts.REHEARSAL)
        self.assertEqual(guard("browser_console", {"expression": "1+1"})["message"], receipts.REHEARSAL)
        self.assertEqual(guard("terminal", {"command": "ls"})["message"], receipts.REHEARSAL)

    def test_the_reply_is_silenced_from_memory(self):
        # Even with every file gone, the decision made at the start silences the reply.
        for path in self.root.iterdir():
            path.unlink()
        self.rec.settings = Untouchable()
        self.rec.jobs = None
        self.assertEqual(self.rec.transform_reply(response_text="I would have sent sk-abcdefgh12345678.", session_id="s"),
                         "[SILENT]")
        self.rec.settings = night.Settings(self.root, clock=self.clock)
        replies = [l for l in self.lines(self.rec) if l["event"] == "reply"]
        self.assertEqual(len(replies), 1)
        self.assertNotIn("sk-abcdefgh", replies[0]["text"])

    def test_the_reply_is_kept_even_when_the_transform_did_not_run(self):
        self.rec.llm_reply(session_id="s", assistant_response="Price is 119.")
        self.rec.llm_reply(session_id="s", assistant_response="[SILENT]")
        self.assertEqual([l["text"] for l in self.lines(self.rec) if l["event"] == "reply"], ["Price is 119."])

    def test_a_real_run_keeps_its_reply(self):
        self.registry([self.on_entry()], since=night.read_settings(self.root)["rehearsals_since"])
        self.run_now = execution(execution_id="e-99")
        rec = self.make()
        rec.session_start(session_id="s2")
        self.assertIsNone(rec.transform_reply(response_text="Done.", session_id="s2"))

    def test_start_call_result_and_end_lines(self):
        self.assertEqual(self.rec.guard(tool_name="write_file", args=WRITE, task_id="cron:3f2a9c:e-81",
                                        session_id="s", tool_call_id="c1")["message"], receipts.REHEARSAL)
        self.rec.record_call(tool_name="write_file", args=WRITE, task_id="cron:3f2a9c:e-81",
                             session_id="s", tool_call_id="c1")
        self.rec.record_result(tool_name="write_file", args=WRITE,
                               result=json.dumps({"error": receipts.REHEARSAL}), task_id="cron:3f2a9c:e-81",
                               session_id="s", tool_call_id="c1", status="blocked")
        self.rec.session_end(session_id="s", task_id="cron:3f2a9c:e-81", completed=True, failed=False)
        lines = self.lines(self.rec)
        self.assertEqual([l["event"] for l in lines], ["start", "call", "result", "end"])
        self.assertEqual(lines[0]["rehearsal"], True)
        self.assertEqual(lines[0]["job_id"], "3f2a9c")
        self.assertEqual(lines[1]["receipt"], {"kind": "held"})
        self.assertEqual(lines[1]["target"], "/tmp/a")
        self.assertEqual(lines[2]["status"], "blocked")
        self.assertEqual(lines[2]["block"], "held")
        self.assertEqual(lines[3]["outcome"], "done")
        for path in (self.root / "receipts", self.root / "receipts" / self.profile):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        day = next((self.root / "receipts" / self.profile).glob("*.jsonl"))
        self.assertEqual(day.stat().st_mode & 0o777, 0o600)


class AskFirstReceiptTests(RecorderCase):
    """Calls Ask first holds in an unattended run: its own hook blocks them, the recorder keeps the receipt."""

    RM = {"command": "rm -rf build"}
    SEND = {"message": "Price drop", "target": "telegram"}

    def setUp(self):
        super().setUp()
        self.turn_on()
        self.run_now = execution()
        self.rec = self.make()

    def test_the_verdict_names_ask_first_outside_a_rehearsal(self):
        run = self.rec.identify("cron:3f2a9c:e-81", "s")
        settings = self.rec.active()
        self.assertEqual(self.rec.verdict(run, "terminal", self.RM, settings), "ask_first")
        self.assertEqual(self.rec.verdict(run, "send_message", self.SEND, settings), "ask_first")
        self.assertIsNone(self.rec.verdict(run, "terminal", {"command": "df -h"}, settings))
        # A click is held only after Ask first reads the screen: the receipt doesn't guess.
        self.assertIsNone(self.rec.verdict(run, "mcp__cua__computer_click", {"sandbox": "local:dev", "x": 1, "y": 2},
                                           settings))
        # The Mac and the add-on's own folder still come first.
        self.assertEqual(self.rec.verdict(run, "computer_use", {"action": "click"}, settings), "mac")

    def test_in_a_rehearsal_ask_first_still_names_what_it_holds(self):
        self.turn_on(rehearsals=True)
        self.registry([], since=night.read_settings(self.root)["rehearsals_since"])
        rec = self.make()
        run = rec.identify("cron:3f2a9c:e-81", "s")
        for tool, args in (("terminal", self.RM), ("send_message", self.SEND)):
            self.assertEqual(rec.verdict(run, tool, args, rec.active()), "ask_first", tool)
            # Ask first's own hook blocks it, so the guard stays out of the way.
            self.assertIsNone(rec.guard(tool_name=tool, args=args, session_id="s"), tool)
        # Anything else that isn't look-only is held as a rehearsal.
        self.assertEqual(rec.verdict(run, "write_file", WRITE, rec.active()), "held")
        self.assertEqual(rec.guard(tool_name="write_file", args=WRITE, session_id="s")["message"], receipts.REHEARSAL)
        rec.session_start(session_id="s")
        rec.record_call(tool_name="send_message", args=self.SEND, task_id="cron:3f2a9c:e-81", session_id="s",
                        tool_call_id="c1")
        call = [l for l in self.lines(rec) if l["event"] == "call"][0]
        self.assertEqual(call["receipt"], {"kind": "held", "detail": "ask_first"})

    def test_the_guard_leaves_the_hold_to_ask_first(self):
        for tool, args in (("terminal", self.RM), ("send_message", self.SEND)):
            self.assertIsNone(self.rec.guard(tool_name=tool, args=args, task_id="cron:3f2a9c:e-81", session_id="s"))

    def test_the_receipt_reads_in_plain_words(self):
        ask_first = load("ask_first")
        held = ask_first.HELD_MESSAGE.format(summary="Run this command:\nrm -rf build")
        self.rec.record_call(tool_name="terminal", args=self.RM, task_id="cron:3f2a9c:e-81", session_id="s",
                             tool_call_id="c1")
        self.rec.record_result(tool_name="terminal", args=self.RM, result=json.dumps({"error": held}),
                               task_id="cron:3f2a9c:e-81", session_id="s", tool_call_id="c1", status="blocked")
        self.rec.record_call(tool_name="terminal", args={"command": "df -h"}, task_id="cron:3f2a9c:e-81",
                             session_id="s", tool_call_id="c2")
        lines = self.lines(self.rec)
        self.assertEqual([l["event"] for l in lines], ["start", "call", "result", "call"])
        self.assertEqual(lines[1]["receipt"], {"kind": "held", "detail": "ask_first"})
        self.assertEqual(lines[1]["target"], "Run this command:\nrm -rf build\nWhy Nollie asks: rm deletes files.")
        self.assertEqual((lines[2]["status"], lines[2]["block"]), ("blocked", "ask_first"))
        # Calls Ask first lets through keep their usual target.
        self.assertEqual(lines[3]["target"], "df -h")

    def test_a_held_targets_secrets_are_scrubbed(self):
        self.rec.record_call(tool_name="send_message", args={"message": "key sk-abcdefghijklmnop1234567890"},
                             task_id="cron:3f2a9c:e-81", session_id="s", tool_call_id="c1")
        [_, call] = self.lines(self.rec)
        self.assertEqual(call["receipt"], {"kind": "held", "detail": "ask_first"})
        self.assertNotIn("sk-abcdefghijklmnop", call["target"])
        self.assertTrue(call["target"].startswith("Send"))


class RecorderNeverBlocksTests(RecorderCase):
    def setUp(self):
        super().setUp()
        self.turn_on()
        self.run_now = execution()

    def test_raising_checks_still_record_and_return_none(self):
        rec = self.make(checks=Checks(hardline=RuntimeError("Hermes moved")))
        self.assertIsNone(rec.record_call(tool_name="terminal", args={"command": "df"}, session_id="s", tool_call_id="c"))
        call = [l for l in self.lines(rec) if l["event"] == "call"][0]
        self.assertEqual(call["receipt"], {"kind": "unknown"})

    def test_a_broken_queue_returns_none(self):
        rec = self.make()

        class Broken:
            def put(self, item):
                raise RuntimeError("full disk")
        rec.writer = Broken()
        self.assertIsNone(rec.record_call(tool_name="terminal", args={"command": "df"}, session_id="s"))
        self.assertIsNone(rec.record_result(tool_name="terminal", result="{}", status="ok", session_id="s"))

    def test_a_full_queue_drops_and_counts(self):
        rec = self.make()
        rec.writer = recorder.Writer(self.root, self.profile, limit=2, start=False)
        for index in range(5):
            rec.record_call(tool_name="terminal", args={"command": f"echo {index}"}, session_id="s",
                            tool_call_id=str(index))
        self.assertEqual(rec.writer.dropped, 4)  # The start line takes one of the two places.
        self.assertEqual(len(self.lines(rec)), 2)
        counts = night.read_unrecorded(self.root, self.profile, AT - 10, AT + 10)
        self.assertEqual(counts, {"cron:3f2a9c:e-81": 4})

    def test_a_full_day_file_takes_no_more_lines(self):
        rec = self.make()
        rec.writer = recorder.Writer(self.root, self.profile, day_limit=10, start=False)
        rec.record_call(tool_name="terminal", args={"command": "df"}, session_id="s")
        rec.record_call(tool_name="terminal", args={"command": "du"}, session_id="s")
        self.assertEqual(len(self.lines(rec)), 1)
        self.assertEqual(night.read_unrecorded(self.root, self.profile, AT - 10, AT + 10), {"cron:3f2a9c:e-81": 2})

    def test_a_bot_marked_private_stops_recording(self):
        rec = self.make()
        rec.record_call(tool_name="terminal", args={"command": "df"}, session_id="s")
        self.private = frozenset({self.profile})
        self.clock.value += 61
        self.assertEqual(self.lines(rec), [])
        self.assertFalse((self.root / "receipts" / self.profile).exists())

    def test_a_bot_whose_name_holds_a_private_one_stops_recording(self):
        self.profile = "work-bot"
        rec = self.make()
        rec.private_names = lambda: recorder.private_bots.names(self.home)  # The saved list, as installed.
        recorder.private_bots.save(self.home, ["nowhere"])
        rec.record_call(tool_name="terminal", args={"command": "df"}, session_id="s")
        self.assertEqual(len(self.lines(rec)), 2)
        recorder.private_bots.save(self.home, ["work"])
        self.clock.value += 61
        rec.record_call(tool_name="terminal", args={"command": "du"}, session_id="s")
        self.assertEqual([l.get("target") for l in self.lines(rec)], [None, "df"], "nothing more once it is private")

    def test_a_damaged_private_list_counts_as_private(self):
        rec = self.make()
        rec.private_names = lambda: (_ for _ in ()).throw(ValueError("damaged"))
        rec.record_call(tool_name="terminal", args={"command": "df"}, session_id="s")
        self.assertEqual(self.lines(rec), [])


class OtherHookTests(RecorderCase):
    def setUp(self):
        super().setUp()
        self.turn_on()

    def test_creating_a_schedule_wakes_the_sweep(self):
        self.run_now = execution()
        rec = self.make()
        rec.record_result(tool_name="cronjob_manage", args={"action": "list"}, result="{}", status="ok", session_id="s")
        rec.writer.drain()
        self.assertFalse((self.root / recorder.WAKE_FLAG).exists())
        rec.record_result(tool_name="cronjob", args={"action": "create"}, result="{}", status="ok", session_id="s")
        rec.writer.drain()
        self.assertTrue((self.root / recorder.WAKE_FLAG).exists())

    def test_always_answers_are_kept_from_any_chat(self):
        rec = self.make()
        rec.approval(choice="once", pattern_key="git push")
        rec.approval(choice="always", pattern_key="git push", pattern_keys=["git push"], description="git push",
                     session_key="chat")
        lines = self.lines(rec)
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["event"], "always")
        self.assertEqual(lines[0]["keys"], ["git push"])

    def test_heartbeat(self):
        rec = self.make()
        rec.heartbeat()
        beat = json.loads((self.root / "recorders" / "career.json").read_text())
        self.assertEqual(beat["version"], 1)
        self.assertEqual(beat["at"], AT)

    def test_register_puts_the_guard_first(self):
        hooks = []
        ctx = type("Ctx", (), {"register_hook": lambda self, name, fn: hooks.append((name, fn.__name__)),
                               "current_cron_execution": lambda self: None})()
        import sys
        from types import SimpleNamespace
        from unittest.mock import patch
        with patch.dict(sys.modules, {"agent": None, "agent.redact": None}):
            recorder.register(ctx, self.home, "career")
        self.assertEqual(hooks[:2], [("pre_tool_call", "guard"), ("pre_tool_call", "record_call")])
        self.assertEqual({name for name, _ in hooks}, {"pre_tool_call", "post_tool_call", "on_session_start",
                         "on_session_end", "post_llm_call", "transform_llm_output", "post_approval_response"})
        self.assertTrue((self.root / "recorders" / "career.json").exists())


class ExitTests(RecorderCase):
    def setUp(self):
        super().setUp()
        self.turn_on()

    def test_lines_still_queued_are_written_at_exit(self):
        self.run_now = execution()
        rec = self.make()
        rec.session_start(session_id="s")
        rec.session_end(session_id="s", completed=True)
        rec.writer.flush()
        events = [line["event"] for line in self.lines(rec)]
        self.assertEqual(events, ["start", "end"])

    def test_flush_is_bounded_and_never_raises(self):
        rec = self.make()
        rec.writer.put({"v": 1, "at": AT, "run": "r", "event": "end", "outcome": "done"})
        later = iter([0.0, 5.0])
        rec.writer.flush(seconds=2.0, clock=lambda: next(later))
        self.assertEqual(rec.writer.queue.qsize(), 1)  # Out of time: left as it was.
        self.root.parent.joinpath("blocked").write_text("")
        broken = recorder.Writer(self.root.parent / "blocked", "career", start=False)
        broken.put({"v": 1, "at": AT, "run": "r", "event": "end", "outcome": "done"})
        self.assertIsNone(broken.flush())
        self.assertTrue(broken.queue.empty())

    def test_register_flushes_at_exit_and_on_unload(self):
        import atexit
        import sys
        from types import SimpleNamespace
        from unittest.mock import patch
        unload = []
        ctx = SimpleNamespace(register_hook=lambda name, fn: None, current_cron_execution=lambda: None,
                              on_unload=unload.append)
        with patch.dict(sys.modules, {"agent": None, "agent.redact": None}), \
                patch.object(atexit, "register") as registered, patch.object(atexit, "unregister") as unregistered:
            rec = recorder.register(ctx, self.home, "career")
            registered.assert_called_once_with(rec.writer.flush)
            self.assertEqual(len(unload), 1)
            with patch.object(rec.writer, "flush") as flushed:
                unload[0]()
            flushed.assert_called_once_with()
            unregistered.assert_called_once()


class SettingsTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.clock = Clock(100.0)

    def test_missing_means_off_and_reads_are_cached(self):
        settings = night.Settings(self.root, clock=self.clock)
        self.assertFalse(settings.get()["night_shift"])
        night.write_settings(self.root, night_shift=True)
        self.assertFalse(settings.get()["night_shift"])  # Within ten seconds: the cached answer.
        self.clock.value += 10
        self.assertTrue(settings.get()["night_shift"])
        self.assertEqual((self.root / night.SETTINGS_NAME).stat().st_mode & 0o777, 0o600)

    def test_damaged_means_both_on_with_the_last_good_values(self):
        night.write_settings(self.root, morning_hour=6)
        settings = night.Settings(self.root, interval=0, clock=self.clock)
        self.assertEqual(settings.get()["morning_hour"], 6)
        (self.root / night.SETTINGS_NAME).write_text('{"version": 1, "night_shift": "yes"}')
        value = settings.get()
        self.assertEqual((value["night_shift"], value["rehearsals"], value["morning_hour"]), (True, True, 6))
        self.assertTrue(value["damaged"])

    def test_turning_rehearsals_on_stamps_when(self):
        first = night.write_settings(self.root, rehearsals=True)
        self.assertIsInstance(first["rehearsals_since"], int)
        self.assertEqual(night.write_settings(self.root, rehearsals=True)["rehearsals_since"], first["rehearsals_since"])
        (self.root / night.SETTINGS_NAME).write_text("{")
        repaired = night.write_settings(self.root, night_shift=True)
        self.assertTrue(repaired["night_shift"])


if __name__ == "__main__":
    unittest.main()
