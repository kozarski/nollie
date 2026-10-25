import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest


spec = importlib.util.spec_from_file_location("board_attention_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class BoardAttentionFixtureTests(unittest.TestCase):
    def setUp(self):
        self.original_boards = copy.deepcopy(mock.KANBAN_BOARDS)
        self.original_tasks = copy.deepcopy(mock.KANBAN_TASKS)
        self.original_events = copy.deepcopy(mock.KANBAN_EVENTS)
        self.original_cursor = mock.KANBAN_CURSOR[:]
        mock.PASSWORD_AUTH["enabled"] = False

    def tearDown(self):
        mock.KANBAN_BOARDS[:] = self.original_boards
        mock.KANBAN_TASKS.clear()
        mock.KANBAN_TASKS.update(self.original_tasks)
        mock.KANBAN_EVENTS.clear()
        mock.KANBAN_EVENTS.update(self.original_events)
        mock.KANBAN_CURSOR[:] = self.original_cursor

    def request(self, path="/api/plugins/nollie-workflow/attention", method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def task(self, tid, status="blocked", kind=None, **fields):
        result = mock._ktask(tid, "Synthetic task " + tid, status, "default")
        result.update(block_kind=kind, **fields)
        return result

    def test_default_fixture_excludes_routine_review_without_mutating_cards(self):
        status, payload = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"counts": {"default": 4, "homelab": 0}})
        self.assertEqual(mock.KANBAN_TASKS, self.original_tasks)

    def test_only_human_blockers_count_across_boards(self):
        mock.KANBAN_TASKS["default"] = [
            self.task("review", "review"), self.task("working", "running"), self.task("done", "done"),
            self.task("transient", kind="transient"), self.task("dependency", kind="dependency"),
            self.task("question", kind="needs_input"), self.task("permission", kind="capability"),
            self.task("legacy"), self.task("archived", "archived"),
        ]
        mock.KANBAN_TASKS["homelab"] = [self.task("work-question", assignee="work", kind="needs_input")]
        self.assertEqual(self.request()[1], {"counts": {"default": 3, "homelab": 1}})

    def test_private_ownership_and_archived_boards_are_excluded(self):
        mock.KANBAN_TASKS["default"] = [self.task("public")]
        for index, field in enumerate(("assignee", "created_by", "tenant")):
            mock.KANBAN_TASKS["default"].append(self.task(str(index), **{field: "profile:private"}))
        mock.KANBAN_TASKS["default"].append(self.task("moss", created_by="Moss"))
        mock.KANBAN_TASKS["default"].append(self.task("unknown", assignee="unlisted"))
        mock.KANBAN_BOARDS.extend([{"slug": "private", "archived": False},
                                  {"slug": "old", "archived": True}])
        # These are deliberately unreadable: excluded boards must not touch their tasks.
        mock.KANBAN_TASKS.update(private=None, old=None)
        self.assertEqual(self.request()[1], {"counts": {"default": 1, "homelab": 0}})

    def test_move_to_blocked_and_resolution_update_counts(self):
        path = "/api/plugins/kanban/tasks"
        _, created = self.request(path, "POST", {"title": "Synthetic drag", "assignee": "work"})
        self.assertEqual(self.request()[1]["counts"]["default"], 4)
        tid = created["task"]["id"]
        status, moved = self.request(path + "/" + tid, "PATCH",
                                     {"status": "blocked", "block_reason": "Choose a destination."})
        self.assertEqual(status, 200)
        self.assertEqual(moved["task"]["latest_summary"], "Choose a destination.")
        self.assertEqual(self.request()[1]["counts"]["default"], 5)
        self.request(path + "/" + tid, "PATCH", {"status": "todo"})
        self.assertEqual(self.request()[1]["counts"]["default"], 4)
        self.request(path + "/" + tid, "DELETE")
        self.assertEqual(self.request()[1]["counts"]["default"], 4)

    def test_nondefault_profile_is_refused(self):
        self.assertEqual(self.request("/api/plugins/nollie-workflow/attention?profile=work")[0], 403)


if __name__ == "__main__":
    unittest.main()
