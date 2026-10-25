import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("activity_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class ActivityFixtureTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.original_flag = mock.ACTIVITY_DEMO
        mock.ACTIVITY_DEMO = True
        mock.LIVE.clear()

    async def asyncTearDown(self):
        mock.ACTIVITY_DEMO = self.original_flag
        mock.LIVE.clear()

    async def test_rest_and_resume_keep_step_identity_and_results(self):
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.ACTIVITY_SESSION)
        owner, rest = mock.seeded_messages(row)
        gateway = mock.Gateway(None)
        reply = await gateway.handle({"jsonrpc": "2.0", "id": 1, "method": "session.resume",
                                      "params": {"session_id": row["id"], "profile": "work"}})
        history = reply["result"]["messages"]
        self.assertEqual(owner, "work")
        self.assertEqual(len(rest), 6)
        self.assertEqual(reply["result"]["message_count"], 6)
        self.assertEqual([item["role"] for item in rest], ["user", "assistant", "tool", "tool", "tool", "assistant"])
        for raw, resumed in zip(rest, history):
            self.assertEqual(raw["id"], resumed["row_id"])
            self.assertEqual(raw["timestamp"], resumed["timestamp"])
            self.assertEqual(raw["content"], resumed["text"])
            self.assertEqual(raw.get("name"), resumed.get("name"))
            self.assertEqual(raw.get("context"), resumed.get("context"))
            self.assertEqual(raw.get("args"), resumed.get("args"))
        self.assertEqual([item["name"] for item in rest if item["role"] == "tool"], ["read_file", "search_files", "terminal"])
        self.assertEqual(history[4]["text"], "3 passed in 0.42s\nExport checks passed.")
        self.assertEqual(history[4]["args"], {"command": "python3 -m pytest tests/test_export.py -q",
                                           "cwd": "~/Projects/exports", "timeout": 30})

    async def test_default_work_fixture_is_unchanged_without_the_flag(self):
        mock.ACTIVITY_DEMO = False
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.ACTIVITY_SESSION)
        _, rest = mock.seeded_messages(row)
        self.assertEqual(len(rest), 4)
        self.assertFalse(any(item["role"] == "tool" for item in rest))
        gateway = mock.Gateway(None)
        reply = await gateway.handle({"jsonrpc": "2.0", "id": 2, "method": "session.resume",
                                      "params": {"session_id": row["id"], "profile": "work"}})
        self.assertEqual(reply["result"]["message_count"], 4)


if __name__ == "__main__":
    unittest.main()
