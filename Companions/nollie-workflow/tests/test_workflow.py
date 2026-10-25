import contextlib
import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("workflow_test_package", ROOT / "__init__.py",
                                             submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = package
spec.loader.exec_module(package)
from workflow_test_package import workflow_core as core, hermes_adapter as adapter, private_bots

# Fixture profiles as Hermes would list them. "private" exists to prove the carry-over.
PROFILES = ("default", "career", "nowhere", "forager", "private")
CARRIED = core.Bots(PROFILES, private_bots.carried_over_names())


def record(event_id=1, kind="review_requested", state="review", board="default", profile="nowhere", at=101):
    return {"board": board, "task": {"id": "task-1", "title": "Check the report", "assignee": profile,
            "created_by": "default", "tenant": "work", "status": state, "session_id": "origin-session",
            "block_kind": None}, "event": {"id": event_id, "kind": kind, "run_id": 12,
            "created_at": at, "payload": {"summary": "The report is ready."}}}


class Source:
    def __init__(self, events):
        self.events = events

    def read(self, cursors, since):
        # Simulate replay, including a server returning already-seen IDs.
        return {"events": self.events, "cursors": {"default": {"task-1": max([e["event"]["id"] for e in self.events] or [0])}}}

    def validate(self, item):
        return True

    def bots(self):
        return CARRIED


class Delivery:
    def __init__(self):
        self.receipts, self.calls = {}, []

    def enqueue(self, key, content):
        self.calls.append(key)
        if key in self.receipts:
            assert self.receipts[key]["content"] == content
        return self.receipts.setdefault(key, {"status": "queued", "content": content})

    def receipt(self, key):
        return self.receipts.get(key)

    def discard_unstarted(self, key, content):
        receipt = self.receipts.get(key)
        if receipt and receipt["status"] == "queued":
            receipt["status"] = "suppressed"
        return receipt


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        state = core.initial_state(100)
        state["enabled"] = True
        core.atomic_write(self.root / "state.json", state)
        self.delivery = Delivery()

    def engine(self, events):
        return core.Engine(self.root, Source(events), self.delivery, now=lambda: 200)

    def test_review_queues_once_across_process_restart_and_replay(self):
        self.engine([record()]).tick()
        self.engine([record()]).tick()
        self.assertEqual(len(self.delivery.calls), 1)
        self.assertEqual(core.read_state(self.root)["cursors"], {"default": {"task-1": 1}})

    def test_first_poll_preserves_event_since_install_and_skips_old_backlog(self):
        items = [record(1, at=99), record(2, at=100), record(3, at=110)]
        for item in items:
            item["task"]["id"] = "task-" + str(item["event"]["id"])
        self.engine(items).tick()
        self.assertEqual(len(self.delivery.receipts), 2)

    def test_pause_never_reads_or_delivers(self):
        state = core.read_state(self.root)
        state["enabled"] = False
        core.atomic_write(self.root / "state.json", state)
        engine = self.engine([record()])
        with patch.object(engine.source, "read", side_effect=AssertionError("read while paused")):
            engine.tick()
        self.assertFalse(self.delivery.calls)

    def test_outbox_is_saved_before_delivery_and_retry_keeps_same_id(self):
        original = self.delivery.enqueue
        def fail(key, content):
            state = core.read_state(self.root)
            self.assertEqual(state["outbox"][key]["status"], "pending")
            self.assertEqual(state["cursors"]["default"]["task-1"], 1)
            raise OSError("not ready")
        with patch.object(self.delivery, "enqueue", side_effect=fail):
            self.engine([record()]).tick()
        self.assertEqual(next(iter(core.read_state(self.root)["outbox"].values()))["error"], "OSError")
        self.engine([record()]).tick()
        self.assertEqual(len(self.delivery.receipts), 1)
        self.assertEqual(next(iter(core.read_state(self.root)["outbox"].values()))["attempts"], 2)

    def test_crash_after_enqueue_does_not_create_a_second_receipt(self):
        original = self.delivery.enqueue
        def crash(key, content):
            original(key, content)
            raise KeyboardInterrupt()
        with patch.object(self.delivery, "enqueue", side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                self.engine([record()]).tick()
        self.engine([record()]).tick()
        self.assertEqual(len(self.delivery.receipts), 1)
        self.assertEqual(len(set(self.delivery.calls)), 1)

    def test_retry_after_upgrade_uses_exact_persisted_content(self):
        original = self.delivery.enqueue
        def crash(key, content):
            original(key, content)
            raise KeyboardInterrupt()
        with patch.object(self.delivery, "enqueue", side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                self.engine([record()]).tick()
        with patch.object(core, "prompt", return_value="new prompt after an upgrade"):
            self.engine([]).tick()
        item = next(iter(core.read_state(self.root)["outbox"].values()))
        self.assertEqual(item["status"], "accepted")
        self.assertEqual(item["content"], next(iter(self.delivery.receipts.values()))["content"])

    def test_pending_retry_revalidates_ownership_before_enqueue(self):
        with patch.object(self.delivery, "enqueue", side_effect=OSError()):
            self.engine([record()]).tick()
        engine = self.engine([])
        with patch.object(engine.source, "validate", return_value=False):
            engine.tick()
        self.assertFalse(self.delivery.calls)
        self.assertEqual(next(iter(core.read_state(self.root)["outbox"].values()))["status"], "superseded")

    def test_validation_failure_retries_without_delivering(self):
        engine = self.engine([record()])
        with patch.object(engine.source, "validate", side_effect=OSError()):
            engine.tick()
        self.assertFalse(self.delivery.calls)
        self.assertEqual(next(iter(core.read_state(self.root)["outbox"].values()))["status"], "pending")
        engine.tick()
        self.assertEqual(len(self.delivery.calls), 1)

    def test_bad_accepted_receipt_does_not_block_later_pending_work(self):
        self.engine([record()]).tick()
        with patch.object(self.delivery, "receipt", side_effect=ValueError()):
            self.engine([record(2)]).tick()
        self.assertEqual(len(self.delivery.receipts), 2)
        self.assertEqual(sum(item.get("error") == "ValueError"
                             for item in core.read_state(self.root)["outbox"].values()), 1)

    def test_unload_after_read_prevents_new_delivery_and_cursor_consumption(self):
        engine = self.engine([record()])
        stopped = False
        original = engine.source.read
        def read(*args):
            nonlocal stopped
            stopped = True
            return original(*args)
        engine.should_stop = lambda: stopped
        with patch.object(engine.source, "read", side_effect=read):
            engine.tick()
        self.assertFalse(self.delivery.calls)
        self.assertEqual(core.read_state(self.root)["cursors"], {})

    def test_unload_during_batch_stops_after_inflight_enqueue(self):
        other = record(2)
        other["task"]["id"] = "task-2"
        engine = self.engine([record(), other])
        stopped = False
        original = self.delivery.enqueue
        def enqueue(*args):
            nonlocal stopped
            stopped = True
            return original(*args)
        engine.should_stop = lambda: stopped
        with patch.object(self.delivery, "enqueue", side_effect=enqueue):
            engine.tick()
        self.assertEqual(len(self.delivery.calls), 1)
        self.assertEqual([item["status"] for item in core.read_state(self.root)["outbox"].values()],
                         ["accepted", "pending"])

    def test_newer_outcome_supersedes_pending_old_review_even_when_status_matches(self):
        with patch.object(self.delivery, "enqueue", side_effect=OSError()):
            self.engine([record()]).tick()
        self.engine([record(3)]).tick()
        items = list(core.read_state(self.root)["outbox"].values())
        self.assertEqual([item["status"] for item in items], ["superseded", "accepted"])
        self.assertEqual(len(self.delivery.calls), 1)

    def test_superseding_unacknowledged_queue_cancels_only_unstarted_receipt(self):
        original = self.delivery.enqueue
        def crash(key, content):
            original(key, content)
            raise KeyboardInterrupt()
        with patch.object(self.delivery, "enqueue", side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                self.engine([record()]).tick()
        self.engine([record(3)]).tick()
        self.assertEqual([r["status"] for r in self.delivery.receipts.values()], ["suppressed", "queued"])

    def test_board_and_task_are_part_of_receipt_identity(self):
        self.engine([record(board="default"), record(board="work")]).tick()
        self.assertEqual(len(self.delivery.receipts), 2)

    def test_receipt_failure_is_observed_without_replaying_turn(self):
        self.engine([record()]).tick()
        next(iter(self.delivery.receipts.values()))["status"] = "ambiguous"
        self.engine([record()]).tick()
        self.assertEqual(len(self.delivery.calls), 1)
        self.assertEqual(core.status(self.root)["receipts"], {"ambiguous": 1})

    def test_non_actionable_events_and_resolved_outcomes_stay_quiet(self):
        self.engine([record(kind="heartbeat", state="running"),
                     record(2, kind="crashed", state="ready"),
                     record(3, kind="blocked", state="done"),
                     record(4, kind="review_requested", state="done")]).tick()
        self.assertFalse(self.delivery.calls)

    def test_all_supported_outcomes_queue(self):
        pairs = [("completed", "done"), ("review_requested", "review"),
                 ("changes_requested", "ready"), ("blocked", "blocked"),
                 ("gave_up", "triage"), ("block_loop_detected", "triage"), ("timed_out", "triage")]
        items = [record(i + 1, kind=k, state=s) for i, (k, s) in enumerate(pairs)]
        for item in items:
            item["task"]["id"] = "task-" + str(item["event"]["id"])
        self.engine(items).tick()
        self.assertEqual(len(self.delivery.receipts), len(pairs))

    def test_private_assignee_creator_tenant_event_and_board_rejected(self):
        cases = [record(1, profile="private"), record(2, board="moss")]
        for i, field in enumerate(("created_by", "tenant"), 3):
            item = record(i)
            item["task"][field] = "profile:private"
            cases.append(item)
        item = record(5)
        item["event"]["payload"]["reviewer"] = "private"
        cases.append(item)
        self.engine(cases).tick()
        self.assertFalse(self.delivery.calls)

    def test_engine_uses_the_sources_current_bots(self):
        engine = self.engine([record(1, profile="scout"), record(2, board="scout")])
        engine.source.bots = lambda: core.Bots(("default", "nowhere", "scout"), {"scout"})
        engine.tick()
        self.assertFalse(self.delivery.calls)
        engine = self.engine([record(3, profile="scout")])
        engine.source.bots = lambda: core.Bots(("default", "scout"), set())
        engine.tick()
        self.assertEqual(len(self.delivery.calls), 1)

    def test_prompt_names_the_followed_and_private_bots_from_data(self):
        text = core.prompt(record(), core.Bots(("default", "scout", "mason", "secret"), {"secret"}))
        self.assertIn("assigned to default, mason or scout on the exact board", text)
        self.assertIn("Do not access a private bot: secret.", text)
        self.assertNotIn("private bot", core.prompt(record(), core.Bots(("default",), set())))

    def test_prompt_retains_origin_and_contains_silent_action_contract(self):
        text = core.prompt(record(), CARRIED)
        self.assertIn('"session_id": "origin-session"', text)
        self.assertIn('"assignee": "nowhere"', text)
        self.assertIn('"board": "default"', text)
        self.assertIn("continue its already-authorized work", text)
        self.assertIn("[SILENT]", text)
        self.assertIn("already handled", text)

    def test_state_permissions_and_corruption_fail_closed(self):
        self.assertEqual((self.root / "state.json").stat().st_mode & 0o777, 0o600)
        (self.root / "state.json").write_text("not json")
        with self.assertRaises(ValueError):
            self.engine([record()]).tick()
        self.assertFalse(self.delivery.calls)

    def test_active_watch_context_does_not_hide_failures_or_finish_watch(self):
        engine = self.engine([record(kind="blocked", state="blocked")])
        engine.followups = SimpleNamespace(context=lambda r: {
            "watch": {"state": "active", "job_id": "fixture", "next_check_at": "2026-10-20T09:00:00+01:00"}})
        engine.tick()
        self.assertEqual(len(self.delivery.calls), 1)
        content = next(iter(self.delivery.receipts.values()))["content"]
        self.assertIn('"job_id": "fixture"', content)
        self.assertIn("a completed check of an active watch is not a finished watch", content)
        self.assertIn("Never reset a loop guard", content)

    def test_damaged_optional_watch_state_does_not_block_task_outcome(self):
        engine = self.engine([record()])
        def unavailable(_):
            raise ValueError("fixture damaged state")
        engine.followups = SimpleNamespace(context=unavailable)
        engine.tick()
        self.assertEqual(len(self.delivery.calls), 1)
        content = next(iter(self.delivery.receipts.values()))["content"]
        self.assertIn('"unavailable": true', content)
        self.assertNotIn("fixture damaged state", content)



class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.db_marker = self.home / "board-marker"
        self.db_marker.touch()
        self.calls = []
        self.profiles = list(PROFILES)
        self.tasks = {p: [] for p in PROFILES}
        self.events = {}
        self.api = SimpleNamespace(list_boards=lambda **k: [{"slug": "default"}, {"slug": "private"}],
            kanban_db_path=lambda **k: self.db_marker, list_tasks=self.list_tasks, list_events=self.list_events,
            get_task=lambda conn, tid: next(t for ts in self.tasks.values() for t in ts if t.id == tid))
        self.connections = SimpleNamespace(connect_closing=lambda **k: contextlib.nullcontext("connection"))
        self.source = adapter.BoardSource(self.home, board_api=self.api, connections=self.connections,
                                          reader=self.read_board, profile_names=lambda: self.profiles)
        self.scope = patch.object(adapter, "default_scope", side_effect=lambda h: contextlib.nullcontext())
        self.scope.start()
        self.addCleanup(self.scope.stop)

    def list_tasks(self, conn, *, assignee, include_archived):
        self.calls.append(("tasks", assignee))
        return self.tasks.setdefault(assignee, [])

    def list_events(self, conn, task_id):
        self.calls.append(("events", task_id))
        return self.events[task_id]

    def read_board(self, conn, *, cursors, since, profiles, private, include_events=True, only_task_id=None):
        rows = []
        bots = core.Bots(profiles, private)
        for profile in profiles:
            for task in self.list_tasks(conn, assignee=profile, include_archived=True):
                if only_task_id is not None and task.id != only_task_id:
                    continue
                safe = {k: getattr(task, k, None) for k in core.TASK_FIELDS}
                if not core.allowed_task(safe, bots):
                    continue
                events = self.api.list_events(conn, task.id) if include_events else []
                current = self.api.get_task(conn, task.id)
                rows.append({"task": {k: getattr(current, k, None) for k in core.TASK_FIELDS},
                             "events": [vars(event).copy() for event in events]})
        return rows

    def add(self, item):
        task = SimpleNamespace(**item["task"])
        self.tasks.setdefault(task.assignee, []).append(task)
        self.events[task.id] = [SimpleNamespace(**item["event"])]
        return task

    def test_filter_runs_before_event_read_and_payload_is_allowlisted(self):
        item = record()
        item["event"]["payload"]["unrelated_private_context"] = "must not serialize"
        self.add(item)
        hidden = record(2)
        hidden["task"].update(id="secret", created_by="private")
        self.add(hidden)
        result = self.source.read({}, 100)
        self.assertEqual(len(result["events"]), 1)
        self.assertNotIn("must not serialize", json.dumps(result))
        self.assertNotIn(("events", "secret"), self.calls)
        self.assertEqual([v for k, v in self.calls if k == "tasks"], ["career", "default", "forager", "nowhere"])

    def test_counts_exclude_review_transient_dependency_and_private(self):
        for i, (state, kind) in enumerate((("review", None), ("blocked", "transient"),
                ("blocked", "dependency"), ("blocked", "needs_input"), ("blocked", "capability"),
                ("blocked", None))):
            item = record(i + 1, state=state)
            item["task"].update(id=f"t{i}", block_kind=kind)
            self.add(item)
        result = self.source.read({}, 0, include_events=False)
        self.assertEqual(result["counts"], {"default": 3})
        self.assertFalse(any(k == "events" for k, v in self.calls))

    def test_newer_cursor_and_latest_relevant_outcome_win(self):
        self.add(record())
        self.events["task-1"].append(SimpleNamespace(**record(2)["event"]))
        result = self.source.read({}, 100)
        self.assertEqual([r["event"]["id"] for r in result["events"]], [2])
        self.assertEqual(result["cursors"], {"default": {"task-1": 2}})
        self.assertFalse(self.source.read({"default": {"task-1": 2}}, 100)["events"])

    def test_transition_between_task_and_event_read_is_not_lost(self):
        task = self.add(record(state="running"))
        def events(conn, task_id):
            task.status = "review"
            return self.events[task_id]
        self.api.list_events = events
        self.assertEqual(len(self.source.read({}, 100)["events"]), 1)

    def test_private_reassignment_during_read_is_not_serialized(self):
        task = self.add(record())
        def events(conn, task_id):
            task.assignee = "private"
            return self.events[task_id]
        self.api.list_events = events
        self.assertFalse(self.source.read({}, 100)["events"])

    def test_event_between_task_reads_is_recovered_next_poll(self):
        self.add(record(1))
        other = record(3)
        other["task"]["id"] = "task-2"
        self.add(other)
        def events(conn, task_id):
            if task_id == "task-2" and len(self.events["task-1"]) == 1:
                self.events["task-1"].append(SimpleNamespace(**record(2)["event"]))
            return list(self.events[task_id])
        self.api.list_events = events
        first = self.source.read({}, 100)
        self.assertEqual(first["cursors"], {"default": {"task-1": 1, "task-2": 3}})
        second = self.source.read(first["cursors"], 100)
        self.assertEqual([item["event"]["id"] for item in second["events"]], [2])

    def test_pending_validation_excludes_private_reassignment_and_resolved_outcome(self):
        item = record()
        task = self.add(item)
        self.assertTrue(self.source.validate(item))
        task.status = "done"
        self.assertFalse(self.source.validate(item))
        task.status = "review"
        self.tasks[task.assignee].remove(task)
        self.assertFalse(self.source.validate(item))
        self.assertFalse(any(k == "events" for k, v in self.calls))


class PrivateListSourceTests(SourceTests):
    """The followed bots and the private checks come from Hermes's profiles and the saved list."""

    def test_every_listed_profile_is_followed_and_the_carry_over_hides_private(self):
        self.profiles.append("scout")
        for i, profile in enumerate(("scout", "private", "moss"), 1):
            item = record(i, profile=profile)
            item["task"]["id"] = "t-" + profile
            self.add(item)
        result = self.source.read({}, 100)
        self.assertEqual([e["task"]["id"] for e in result["events"]], ["t-scout"])
        self.assertEqual([v for k, v in self.calls if k == "tasks"],
                         ["career", "default", "forager", "nowhere", "scout"])

    def test_once_saved_only_the_list_counts(self):
        private_bots.save(self.home, ["nowhere"])
        for i, profile in enumerate(("nowhere", "private", "career"), 1):
            item = record(i, profile=profile)
            item["task"]["id"] = "t-" + profile
            self.add(item)
        result = self.source.read({}, 100)
        self.assertEqual(sorted(e["task"]["id"] for e in result["events"] if e["board"] == "default"),
                         ["t-career", "t-private"])
        # The board named private is an ordinary board now that the list does not name it.
        self.assertEqual(sorted(result["cursors"]), ["default", "private"])

    def test_private_boards_and_owners_follow_the_list(self):
        private_bots.save(self.home, ["scout"])
        self.api.list_boards = lambda **k: [{"slug": "default"}, {"slug": "scout"}, {"slug": "moss"}]
        hidden = []
        for i, (field, value) in enumerate((("created_by", "scout"), ("tenant", "team:Scout"),
                                             ("created_by", "moss")), 1):
            item = record(i)
            item["task"].update(id=f"t{i}", **{field: value})
            hidden.append(self.add(item))
        item = record(9, board="scout")
        result = self.source.read({}, 100)
        self.assertEqual(sorted(result["cursors"]), ["default", "moss"])
        self.assertEqual(sorted(e["task"]["id"] for e in result["events"] if e["board"] == "default"), ["t3"])
        self.assertFalse(self.source.validate(item))
        self.assertIsNone(self.source.task("scout", "task-1"))
        payload = record(10)
        payload["task"]["id"] = "t10"
        payload["event"]["payload"]["reviewer"] = "Scout"
        self.add(payload)
        self.assertNotIn("t10", [e["task"]["id"] for e in self.source.read({}, 100)["events"]])

    def test_a_profile_removed_from_hermes_is_no_longer_followed(self):
        item = record()
        self.add(item)
        self.assertTrue(self.source.validate(item))
        self.profiles.remove("nowhere")
        self.assertFalse(self.source.validate(item))
        self.assertFalse(self.source.read({}, 100)["events"])

    def test_damaged_list_stops_reading(self):
        self.add(record())
        (self.home / private_bots.FILE_NAME).write_text("{")
        with self.assertRaises(ValueError):
            self.source.read({}, 100)
        self.assertFalse(self.calls)


class DeliveryTests(unittest.TestCase):
    def test_enqueue_targets_default_canonical_lane_with_stable_id(self):
        calls = []
        def defer(*args):
            calls.append(args)
            return {"status": "queued"}
        modules = {"cron": SimpleNamespace(), "cron.bot_chat_delivery": SimpleNamespace(defer=defer)}
        with patch.dict(sys.modules, modules), \
                patch.object(adapter, "default_scope", side_effect=lambda h: contextlib.nullcontext()):
            delivery = adapter.BotChatDelivery(Path("/fixture/default"))
            result = delivery.enqueue("event-key", "exact content")
        self.assertEqual(result, {"status": "queued"})
        self.assertEqual(calls, [("event-key", {"id": "nollie-board-event-key",
            "name": "Board follow-through", "execution_id": "event-key"},
            "exact content", "default", Path("/fixture/default"))])

    def test_live_owner_receipt_is_authoritative_after_transfer(self):
        modules = {"cron": SimpleNamespace(),
            "cron.bot_chat_delivery": SimpleNamespace(read_pending=lambda k: {"status": "transferred"}),
            "tools": SimpleNamespace(),
            "tools.bot_live_delivery": SimpleNamespace(read_delivery_result=lambda h, k: {"status": "completed"})}
        with patch.dict(sys.modules, modules), \
                patch.object(adapter, "default_scope", side_effect=lambda h: contextlib.nullcontext()):
            self.assertEqual(adapter.BotChatDelivery(Path("/fixture/default")).receipt("event-key"),
                             {"status": "completed"})


if __name__ == "__main__":
    unittest.main()
