import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("silence_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class SilenceFixtureTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.original_flag = mock.SILENCE_DEMO
        mock.SILENCE_DEMO = True
        mock.LIVE.clear()

    async def asyncTearDown(self):
        mock.SILENCE_DEMO = self.original_flag
        mock.LIVE.clear()

    async def test_rest_and_resume_keep_raw_automatic_control_replies(self):
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.COMPUTER_SESSION)
        owner, stored = mock.seeded_messages(row)
        reply = await mock.Gateway(None).handle({"jsonrpc": "2.0", "id": 1, "method": "session.resume",
                                                "params": {"session_id": row["id"], "profile": "default"}})
        history = reply["result"]["messages"]
        self.assertEqual(owner, "default")
        self.assertEqual([item["text"] for item in history], [item["content"] for item in stored])
        self.assertEqual([item["row_id"] for item in history], [item["id"] for item in stored])
        self.assertEqual([item["text"].strip() for item in history if item["role"] == "assistant"],
                         ["Your report is ready.", "[SILENT]", "NO_REPLY"])
        self.assertTrue(all(item["text"].startswith('[Cronjob "') for item in history if item["role"] == "user"))

    async def test_literal_user_markers_and_nonempty_assistant_text_remain_raw(self):
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.ACTIVITY_SESSION)
        owner, stored = mock.seeded_messages(row)
        self.assertEqual(owner, "work")
        self.assertEqual([item["content"] for item in stored if item["role"] == "user"], ["[SILENT]", "NO_REPLY"])
        self.assertIn("The marker [SILENT] is literal text.", [item["content"] for item in stored])

    async def test_default_fixture_is_unchanged_without_the_flag(self):
        mock.SILENCE_DEMO = False
        row = next(row for row in mock.STORED_SESSIONS if row["id"] == mock.COMPUTER_SESSION)
        _, stored = mock.seeded_messages(row)
        self.assertTrue(stored[0]["content"].startswith("The log host is at 94% disk."))
        self.assertEqual(mock.rest("/api/_mock/silence", {})[1]["enabled"], False)


if __name__ == "__main__":
    unittest.main()
