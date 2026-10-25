import copy
from datetime import datetime
import importlib.util
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[1]
NAME = "followup_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
module = importlib.util.module_from_spec(spec)
sys.modules[NAME] = module
spec.loader.exec_module(module)
from followup_test_package.followup_policy import Followups, calendar, identity
from followup_test_package.followup_tools import install_gate
from followup_test_package.private_bots import save


def stamp(value):
    return datetime.fromisoformat(value).timestamp()


class Jobs:
    def __init__(self):
        self.job = {"id": "job1", "state": "paused", "enabled": False,
                    "schedule": {"kind": "cron", "expr": "0 9 * * *"},
                    "model": "fixture-local", "provider": "fixture", "prompt": "Check the exact item.",
                    "deliver": "local"}
        self.updates, self.pauses = [], []
        self.fail_pause = False

    def get(self, key):
        return copy.deepcopy(self.job) if key == self.job["id"] else None

    def bind_gate(self, key, expected, script):
        values = {"script": script, "precheck_fail_closed": True}
        self.updates.append((key, values))
        self.job.update(values)
        return copy.deepcopy(self.job)

    def pause_gate(self, key, expected, script, reason):
        self.pauses.append(key)
        if self.fail_pause:
            raise OSError("fixture")
        self.job.update(enabled=False, state="paused")
        return copy.deepcopy(self.job)


class FollowupTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.jobs = Jobs()
        self.clock = stamp("2026-10-20T09:01:00+01:00")
        self.task = {"id": "task1", "status": "todo", "assignee": "default"}
        self.events = {8: {"id": 8, "kind": "completed"}, 9: {"id": 9, "kind": "blocked"}}
        self.private = frozenset({"private", "moss"})
        self.api = Followups(self.root, self.jobs, lambda *_: self.task, now=lambda: self.clock,
                             private=lambda: self.private)
        self.cadence = {"timezone": "Europe/London", "anchor_date": "2026-10-20", "stop_date": "2026-12-14",
                        "every_days": 2, "at": "09:00"}

    def bind(self):
        return self.api.bind_watch("default", "task1", "job1", "Keep watching until I stop.",
                                   "Keep the original variant.", self.cadence, "fixture.py")

    def test_bind_keeps_native_job_paused_and_requires_explicit_pins(self):
        self.jobs.job["model"] = None
        with self.assertRaises(ValueError): self.bind()
        self.assertFalse(self.jobs.updates)
        self.jobs.job["model"] = "fixture-local"
        result = self.bind()
        self.assertEqual(result["state"], "paused")
        self.assertFalse(self.jobs.job["enabled"])
        self.assertEqual(self.jobs.updates, [("job1", {"script": "fixture.py", "precheck_fail_closed": True})])

    def test_finite_repeat_and_authored_execution_edits_are_rejected(self):
        self.jobs.job["repeat"] = {"times": 1, "completed": 0}
        with self.assertRaises(ValueError): self.bind()
        self.jobs.job["repeat"] = {"times": None, "completed": 0}
        self.bind()
        for field, value in [("skills", ["different"]), ("context_from", "another-job"),
                             ("interpreter", "/different/python"), ("workdir", "/other"),
                             ("no_agent", True), ("monitor_url", "https://fixture.invalid"),
                             ("repeat", {"times": 1, "completed": 0})]:
            old = self.jobs.job.get(field)
            self.jobs.job[field] = value
            self.assertFalse(self.api.gate(identity("default", "task1"))["wakeAgent"])
            self.jobs.job[field] = old
        self.jobs.job["repeat"]["completed"] = 5
        self.assertTrue(self.api.gate(identity("default", "task1"))["wakeAgent"])

    def test_existing_active_watch_or_foreign_script_is_not_replaced(self):
        self.jobs.job["script"] = "someone-elses.py"
        with self.assertRaises(ValueError): self.bind()
        self.jobs.job.pop("script")
        self.bind()
        with self.assertRaises(ValueError): self.bind()
        self.assertEqual(len(self.jobs.updates), 1)

    def test_calendar_survives_dst_month_boundary_and_off_day(self):
        self.assertEqual(calendar(self.cadence, stamp("2026-10-24T09:01:00+01:00"))["next_check_at"],
                         "2026-10-26T09:00:00+00:00")
        self.assertEqual(calendar(self.cadence, stamp("2026-10-30T09:01:00+00:00"))["next_check_at"],
                         "2026-11-01T09:00:00+00:00")
        self.bind()
        self.api.record_check("default", "task1", 0, "same-variant", {"price": 100}, ["source:1"])
        self.api.finish_check("default", "task1", 0)
        self.clock = stamp("2026-10-21T09:01:00+01:00")
        self.assertFalse(self.api.gate(identity("default", "task1"))["wakeAgent"])
        self.clock = stamp("2026-10-22T09:01:00+01:00")
        self.assertTrue(self.api.gate(identity("default", "task1"))["wakeAgent"])

    def test_before_anchor_never_wakes_and_missed_cycle_catches_up_once(self):
        self.bind(); self.clock = stamp("2026-10-19T09:01:00+01:00")
        self.assertFalse(self.api.gate(identity("default", "task1"))["wakeAgent"])
        self.clock = stamp("2026-10-23T09:01:00+01:00")
        gate = self.api.gate(identity("default", "task1"))
        self.assertTrue(gate["wakeAgent"]); self.assertEqual(gate["cycle"], 1)
        self.api.record_check("default", "task1", 1, "same", {"available": True}, ["source:1"])
        self.api.finish_check("default", "task1", 1)
        self.assertFalse(self.api.gate(identity("default", "task1"))["wakeAgent"])

    def test_baseline_delta_and_optional_variant_remain_separate(self):
        self.bind()
        first = self.api.record_check("default", "task1", 0, "direct", {"price": 100}, ["source:1"])
        self.assertTrue(first["changed"])
        self.clock = stamp("2026-10-22T09:01:00+01:00")
        second = self.api.record_check("default", "task1", 1, "direct", {"price": 90}, ["source:2"])
        self.assertEqual(second["previous_facts"], {"price": 100})
        alternative = self.api.record_check("default", "task1", 1, "different-date", {"price": 80}, ["source:3"])
        self.assertIsNone(alternative["previous_facts"])
        self.assertEqual(second["watch_state"], "active")
        saved = self.api.status("default", "task1")["followup"]["watch"]
        self.assertEqual(saved["comparisons"]["direct"]["baseline"]["facts"], {"price": 100})

    def test_whole_cycle_finalization_never_hides_a_changed_variant(self):
        self.bind()
        for key in ("a", "b"):
            self.api.record_check("default", "task1", 0, key, {"price": 100}, ["source:1"])
        self.api.finish_check("default", "task1", 0)
        self.clock = stamp("2026-10-22T09:01:00+01:00")
        self.api.record_check("default", "task1", 1, "a", {"price": 100}, ["source:2"])
        self.assertTrue(self.api.gate(identity("default", "task1"))["wakeAgent"])
        self.api.record_check("default", "task1", 1, "b", {"price": 90}, ["source:2"])
        self.assertTrue(self.api.finish_check("default", "task1", 1)["changed"])
        self.clock = stamp("2026-10-24T09:01:00+01:00")
        for key, price in (("a", 100), ("b", 90)):
            self.api.record_check("default", "task1", 2, key, {"price": price}, ["source:3"])
        self.assertEqual(self.api.finish_check("default", "task1", 2)["result"], "[SILENT]")
        with self.assertRaises(ValueError):
            self.api.record_check("default", "task1", 2, "c", {"price": 5}, ["source:3"])
        restarted = Followups(self.root, self.jobs, lambda *_: self.task, now=lambda: self.clock)
        self.assertFalse(restarted.gate(identity("default", "task1"))["wakeAgent"])

    def test_duplicate_receipt_is_idempotent_but_cannot_be_reworded(self):
        self.bind()
        self.api.record_check("default", "task1", 0, "same", {"price": 100}, ["source:1"])
        result = self.api.record_check("default", "task1", 0, "same", {"price": 100}, ["source:1"])
        self.assertTrue(result["duplicate"])
        with self.assertRaises(ValueError):
            self.api.record_check("default", "task1", 0, "same", {"price": 90}, ["source:1"])

    def test_empty_failed_or_invalid_check_cannot_be_finalized(self):
        self.bind()
        with self.assertRaises(ValueError): self.api.finish_check("default", "task1", 0)
        with self.assertRaises(ValueError):
            self.api.record_check("default", "task1", 0, "same", {"price": float("nan")}, ["source:1"])

    def test_stop_closes_gate_even_when_native_pause_fails(self):
        self.bind(); self.jobs.fail_pause = True
        self.api.task_lookup = lambda *_: (_ for _ in ()).throw(OSError("source offline"))
        with self.assertRaises(OSError): self.api.stop("default", "task1", "User booked.")
        self.assertEqual(self.api._load()["tasks"][identity("default", "task1")]["watch"]["state"], "stopped")
        self.jobs.fail_pause = False
        self.assertTrue(self.api.stop("default", "task1", "User booked.")["job_paused"])

    def test_deadline_and_changed_route_do_not_run(self):
        self.bind(); self.jobs.job["provider"] = "other"
        self.assertEqual(self.api.gate(identity("default", "task1"))["reason"], "job_changed")
        self.jobs.job["provider"] = "fixture"
        self.clock = stamp("2026-12-14T09:01:00+00:00")
        self.assertEqual(self.api.gate(identity("default", "task1"))["reason"], "deadline")
        self.assertEqual(self.jobs.pauses, ["job1"])

    def test_stop_does_not_pause_an_edited_native_job(self):
        self.bind(); self.jobs.job["prompt"] = "A different task now."
        result = self.api.stop("default", "task1", "No longer needed.")
        self.assertTrue(result["stopped"])
        self.assertFalse(result["job_paused"])
        self.assertFalse(self.jobs.pauses)

    def test_checkpoint_never_requeues_and_rephrasing_is_not_new_evidence(self):
        args = ("default", "task1", "run1", ["tool-result:1"], "Verified result", "One step", "Read next source")
        self.assertTrue(self.api.checkpoint(*args)["new_evidence"])
        result = self.api.checkpoint(*args[:4], "Reworded result", *args[5:])
        self.assertFalse(result["new_evidence"])
        self.assertFalse(result["continuation_scheduled"])
        self.assertFalse(self.jobs.updates); self.assertFalse(self.jobs.pauses)

    def test_private_or_missing_task_and_human_block_do_not_wake(self):
        for board in ["private", "moss-work"]:
            with self.assertRaises(ValueError): self.api.key(board, "task1")
        self.private = frozenset({"scout"})
        self.assertEqual(self.api.key("private", "task1"), identity("private", "task1"))
        with self.assertRaises(ValueError): self.api.status("scout", "task1")
        self.bind(); self.task = None
        with self.assertRaises(ValueError): self.api.gate(identity("default", "task1"))
        self.task = {"id": "task1", "status": "blocked", "block_kind": "needs_input"}
        self.assertEqual(self.api.gate(identity("default", "task1"))["reason"], "needs_attention")

    def test_default_private_list_is_read_from_the_main_home(self):
        home = self.root / "home"
        api = Followups(home / "nollie-workflow", self.jobs, lambda *_: self.task, now=lambda: self.clock)
        with self.assertRaises(ValueError): api.key("moss", "task1")
        save(home, ["scout"])
        api.key("moss", "task1")
        with self.assertRaises(ValueError): api.key("scout", "task1")

    def test_gate_wrapper_is_fixed_and_never_overwrites_another_script(self):
        key = identity("default", "task1")
        name = install_gate(self.root, key)
        self.assertEqual(install_gate(self.root, key), name)
        path = self.root / "scripts" / name
        self.assertIn("'wakeAgent': False", path.read_text())
        path.write_text("existing file")
        with self.assertRaises(ValueError): install_gate(self.root, key)


if __name__ == "__main__":
    unittest.main()
