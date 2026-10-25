import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("notification_activity_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class NotificationActivityFixtureTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.original_flag = mock.NOTIFICATION_ACTIVITY_DEMO
        mock.NOTIFICATION_ACTIVITY_DEMO = True
        mock.LIVE.clear()

    async def asyncTearDown(self):
        mock.NOTIFICATION_ACTIVITY_DEMO = self.original_flag
        mock.LIVE.clear()

    async def test_worker_dispatcher_differs_from_assignee_without_starting_main_chat(self):
        status, data = mock.kanban_rest("GET", "/api/plugins/kanban/workers/active", {"board": "default"})
        self.assertEqual(status, 200)
        worker = next(item for item in data["workers"] if item["task_id"] == "k-101")
        self.assertEqual(worker["profile"], "default")
        self.assertEqual(worker["task_assignee"], "work")
        self.assertEqual(worker["task_status"], "running")
        self.assertGreater(worker["worker_pid"], 0)
        reply = await mock.Gateway(None).handle({"jsonrpc": "2.0", "id": 1, "method": "session.resume",
                                                "params": {"session_id": mock.ACTIVITY_SESSION, "profile": "work"}})
        self.assertFalse(reply["result"]["running"])
        self.assertNotIn("inflight", reply["result"])

    async def test_rest_and_resume_preserve_trusted_metadata_and_original_messages(self):
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.ACTIVITY_SESSION)
        owner, stored = mock.seeded_messages(row)
        reply = await mock.Gateway(None).handle({"jsonrpc": "2.0", "id": 2, "method": "session.resume",
                                                "params": {"session_id": row["id"], "profile": "work"}})
        self.assertEqual(owner, "work")
        self.assertEqual(len(stored), 6)
        for raw, resumed in zip(stored, reply["result"]["messages"]):
            self.assertEqual(raw["content"], resumed["text"])
            self.assertEqual(raw["id"], resumed["row_id"])
            for key in ("display_kind", "display_metadata", "finish_reason"):
                self.assertEqual(raw.get(key), resumed.get(key))
        self.assertEqual(stored[2]["display_kind"], "internal_notification")
        self.assertEqual(stored[2]["display_metadata"]["notification_category"], "diagnostic")
        self.assertEqual(stored[3]["content"], "[SILENT]")
        self.assertNotIn("display_kind", stored[0])

    async def test_live_preview_is_scoped_and_never_a_running_computer_tool(self):
        query = {"profile": "work", "session_id": mock.ACTIVITY_SESSION}
        first = mock.computer_preview_rest(query)[1]
        second = mock.computer_preview_rest(query)[1]
        self.assertEqual(first["state"], "live")
        self.assertEqual(first["computer_name"], "Work desktop")
        self.assertNotEqual(first["image_data_url"], second["image_data_url"])
        self.assertEqual(mock.computer_preview_rest({**query, "profile": "default"})[1]["state"], "unavailable")
        self.assertFalse(mock.COMPUTER_PREVIEW["active"])
        self.assertEqual(mock.COMPUTER_PREVIEW["writes"], 0)

    async def test_existing_fixtures_are_unchanged_without_the_flag(self):
        mock.NOTIFICATION_ACTIVITY_DEMO = False
        _, data = mock.kanban_rest("GET", "/api/plugins/kanban/workers/active", {"board": "default"})
        worker = next(item for item in data["workers"] if item["task_id"] == "k-101")
        self.assertEqual(worker["profile"], "work")
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.ACTIVITY_SESSION)
        _, stored = mock.seeded_messages(row)
        self.assertEqual(len(stored), 4)
        self.assertFalse(any(item.get("display_kind") for item in stored))
        self.assertEqual(mock.computer_preview_rest({"profile": "work", "session_id": row["id"]})[1]["state"], "idle")


if __name__ == "__main__":
    unittest.main()
