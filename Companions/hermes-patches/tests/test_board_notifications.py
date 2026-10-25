"""The checked Board bridges through Hermes's real notification and binding code."""
import contextlib
import copy
from pathlib import Path
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from support import hermes_module, hermes_source


class BoardNotificationTests(unittest.TestCase):
    def setUp(self):
        source = hermes_source()
        source.__enter__()
        self.addCleanup(source.__exit__, None, None, None)
        self.notifications = hermes_module("tui_gateway.session_notifications")
        self.warnings = hermes_module("gateway.warning_notifications")
        self.submitted = []
        self.emitted = []
        self.failures = []
        self.texts = []
        self.config = {"display": {"suppress_warning_notifications": False}}
        config = patch.object(self.warnings, "effective_user_config", lambda: self.config)
        config.start()
        self.addCleanup(config.stop)
        self.server = SimpleNamespace(
            contextlib=contextlib, time=time, Path=Path,
            _session_profile_runtime_scope=lambda _: contextlib.nullcontext(),
            _session_turn_admission=lambda _: contextlib.nullcontext(True),
            _emit=lambda *args: self.emitted.append(args),
            _run_prompt_submit=lambda *args, **kwargs: self.submitted.append((args[3], kwargs)),
        )
        self.notifications.register(self.server)
        self.server._collect_kanban_notifications = lambda _: self.texts
        self.server._notif_log_failure = lambda *args: self.failures.append(args)
        self.session = {"history_lock": threading.RLock(), "session_key": "fixture-session"}
        self.task = SimpleNamespace(title="Fixture research", assignee="fixture", max_runtime_seconds=None)

    def poll(self, texts=()):
        self.texts = list(texts)
        self.server._notif_poll_kanban_scoped("fixture-live", self.session)

    def format(self, payload, kind="timed_out"):
        event = SimpleNamespace(kind=kind, payload=payload)
        return self.server._format_kanban_event_text({"task_id": "fixture-task"}, self.task, event, "default")

    def test_positive_event_limits_do_not_promise_a_retry(self):
        for value in (1, 90, "120", " 3600 "):
            with self.subTest(value=value):
                text = self.format({"limit_seconds": value, "retry_status": "ready"})
                self.assertIn(f"recorded runtime limit ({int(value)}s)", text)
                self.assertIn("check current task state before retrying", text)
                self.assertNotIn("will retry", text)

    def test_missing_or_invalid_limit_does_not_invent_evidence(self):
        for value in (None, "", 0, "0", -1, "-1", True, False, 1.5, "1.5", "unknown", [], {}, "9" * 5000):
            with self.subTest(value=str(value)[:40]):
                text = self.format({"limit_seconds": value})
                self.assertIn("without a recorded positive runtime limit", text)
                self.assertIn("check the run details before retrying", text)
                self.assertNotIn("max_runtime=0", text)
                self.assertNotIn("iteration", text)
                self.assertNotIn("will retry", text)

    def test_current_settings_are_not_historical_evidence(self):
        self.task.max_runtime_seconds = 600
        self.assertIn("without a recorded positive runtime limit", self.format({}))
        self.assertNotIn("600", self.format({}))
        self.task.max_runtime_seconds = None
        self.assertIn("recorded runtime limit (90s)", self.format({"limit_seconds": 90}))

    def test_iteration_budget_failure_keeps_its_reason(self):
        reason = "Iteration budget exhausted; verified partial result saved."
        text = self.format({"reason": reason, "kind": "transient"}, kind="blocked")
        self.assertIn(reason, text)
        self.assertNotIn("runtime limit", text)
        self.assertNotIn("timed out", text)

    def test_formatting_does_not_change_task_or_event(self):
        payload = {"limit_seconds": 120, "elapsed_seconds": 125, "retry_status": "review"}
        original = copy.deepcopy(payload)
        task = vars(self.task).copy()
        self.format(payload)
        self.assertEqual(payload, original)
        self.assertEqual(vars(self.task), task)

    def test_warning_setting_does_not_change_machine_origin(self):
        text = self.warnings.DiagnosticText(self.format({"limit_seconds": 90}))
        for suppressed in (False, True):
            with self.subTest(suppressed=suppressed):
                self.config["display"]["suppress_warning_notifications"] = suppressed
                self.session["running"] = False
                self.poll([text])
                prompt, kwargs = self.submitted[-1]
                self.assertEqual(prompt, text)
                self.assertEqual(kwargs["display_kind"], "internal_notification")
                metadata = {"notification_category": "diagnostic"} if suppressed else None
                self.assertEqual(kwargs.get("display_metadata"), metadata)
                self.assertEqual(self.session["_kanban_pending"], [])
        self.assertEqual(len(self.submitted), 2)
        self.assertEqual(len(self.emitted), 2)
        self.assertFalse(self.failures)

    def test_busy_session_keeps_one_pending_batch_until_idle(self):
        self.session["running"] = True
        self.poll(["Task finished"])
        self.assertEqual(self.submitted, [])
        self.assertEqual(self.session["_kanban_pending"], ["Task finished"])
        self.session["running"] = False
        self.poll()
        self.assertEqual(self.submitted, [("Task finished", {"display_kind": "internal_notification"})])
        self.session["running"] = False
        self.poll()
        self.assertEqual(len(self.submitted), 1)

    def test_stopped_session_keeps_notifications_until_released(self):
        self.session["_turn_cancel_requested"] = True
        self.poll(["Task finished"])
        self.assertEqual(self.submitted, [])
        self.assertEqual(self.session["_kanban_pending"], ["Task finished"])
        self.session["_turn_cancel_requested"] = False
        self.poll()
        self.assertEqual(self.submitted, [("Task finished", {"display_kind": "internal_notification"})])

    def test_diagnostics_and_results_keep_their_batch_order(self):
        self.config["display"]["suppress_warning_notifications"] = True
        self.poll([self.warnings.DiagnosticText("Check the run details"), "Task finished"])
        self.assertEqual(self.submitted, [("Check the run details", {
            "display_kind": "internal_notification", "display_metadata": {"notification_category": "diagnostic"},
        })])
        self.assertEqual(self.session["_kanban_pending"], ["Task finished"])
        self.session["running"] = False
        self.poll()
        self.assertEqual(self.submitted[-1], ("Task finished", {"display_kind": "internal_notification"}))
        self.assertEqual(self.session["_kanban_pending"], [])

    def test_no_event_does_not_start_a_turn(self):
        self.poll()
        self.assertEqual(self.submitted, [])
        self.assertFalse(self.session.get("running"))

    def test_failed_submission_releases_the_turn(self):
        def fail(*args, **kwargs):
            raise RuntimeError("fixture failure")
        self.server._run_prompt_submit = fail
        self.poll(["Task finished"])
        self.assertFalse(self.session["running"])
        self.assertEqual(len(self.failures), 1)
        self.assertEqual(self.failures[0][0], "kanban notification dispatch failed")

    def test_other_notification_origins_are_not_reclassified(self):
        self.server._notif_submit("fixture", "fixture-live", self.session, "Other event", "fixture failure")
        self.assertEqual(self.submitted, [("Other event", {})])


if __name__ == "__main__":
    unittest.main()
