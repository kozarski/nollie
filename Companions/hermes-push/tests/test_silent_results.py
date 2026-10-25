"""Notification delivery contracts with an in-memory gateway and push sink."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import AsyncMock


SCRIPT = Path(__file__).resolve().parents[1] / "hermes_push.py"
spec = importlib.util.spec_from_file_location("push_silent_test", SCRIPT)
companion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(companion)


class Gateway:
    def __init__(self, reply):
        self.reply = reply
        self.count = 4
        self.reads = []
        self.messages = None

    async def call(self, method, params):
        if method != "profiles.list" or params != {}:
            raise AssertionError((method, params))
        return {"profiles": [{"name": "default", "canonical_session": {
            "id": "bot-chat", "resolved_id": "bot-chat", "message_count": self.count}}]}

    def _http(self, method, path):
        if method != "GET" or path != "/api/sessions/bot-chat/messages?order=latest&limit=6&profile=default":
            raise AssertionError((method, path))
        self.reads.append(path)
        return {"messages": self.messages if self.messages is not None else [
            {"role": "user", "text": '[Cronjob "Board follow-through" output] Task evidence'},
            {"role": "assistant", "text": self.reply},
        ]}


class SilentResultTests(unittest.IsolatedAsyncioTestCase):
    def relay(self, reply):
        relay = companion.Relay.__new__(companion.Relay)
        relay.gw = Gateway(reply)
        relay.labels = {"default": "Nollie"}
        relay.bot_chats = {"default": {"id": "bot-chat", "resolved_id": "bot-chat", "message_count": 2}}
        relay._bot_chat_check_at = 0
        relay._bot_chat_pushed = {}
        relay._turn_pushed_at = {}
        relay._finish_pushed = {}
        relay.attached = {"live": {"stored": "bot-chat", "title": "Bot Chat", "profile": "default", "bot": "Nollie"}}
        relay.pushes, relay.ends = [], []
        relay.push_all = lambda *a, **kw: relay.pushes.append((a, kw))
        relay.end_live_activities = lambda *a, **kw: relay.ends.append((a, kw))
        relay._recent_thread = AsyncMock(return_value=[])
        return relay

    async def test_fallback_silent_markers_do_not_push_and_are_recorded(self):
        for text in ("[SILENT]", "NO_REPLY", " \n[SILENT]\t", " NO_REPLY\n"):
            with self.subTest(text=text):
                relay = self.relay(text)
                self.assertEqual(await relay.check_bot_chats(), 0)
                self.assertEqual(relay.pushes, [])
                self.assertIn(("bot-chat", 4), relay._bot_chat_pushed)
                # A repeated notification at the same count remains silent.
                relay._bot_chat_check_at = 0
                self.assertEqual(await relay.check_bot_chats(), 0)
                self.assertEqual(len(relay.gw.reads), 1)

    async def test_fallback_meaningful_messages_with_marker_words_still_push(self):
        for text in ("The server returned NO_REPLY; please check it.", "[SILENT]\nThe report is ready.",
                     "The marker is [SILENT].", "[silent]", "NO_REPLY: timed out", "Done"):
            with self.subTest(text=text):
                relay = self.relay(text)
                self.assertEqual(await relay.check_bot_chats(), 1)
                self.assertEqual(relay.pushes[0][0][0], "cron")
                self.assertEqual(relay.pushes[0][0][3]["text"], text)

    async def test_real_result_after_silent_result_is_not_suppressed(self):
        relay = self.relay("[SILENT]")
        await relay.check_bot_chats()
        relay.gw.reply, relay.gw.count = "The report is ready for you.", 6
        relay._bot_chat_check_at = 0
        self.assertEqual(await relay.check_bot_chats(), 1)
        self.assertEqual(relay.pushes[0][0][3]["text"], "The report is ready for you.")

    async def test_live_silent_success_finishes_activity_without_push_or_thread_read(self):
        for text in ("[SILENT]", "NO_REPLY"):
            with self.subTest(text=text):
                relay = self.relay(text)
                relay.attached["live"]["source"] = "cron"
                await relay._finish_turn("live", relay.attached["live"], {"text": text})
                self.assertEqual(relay.pushes, [])
                self.assertEqual(relay.ends[0][0], ("bot-chat", "done"))
                relay._recent_thread.assert_not_awaited()
                self.assertIn("bot-chat", relay._turn_pushed_at)

    async def test_human_requested_literal_marker_reply_still_notifies(self):
        for text in ("[SILENT]", "NO_REPLY"):
            relay = self.relay(text)
            await relay._finish_turn("live", relay.attached["live"], {"text": text, "status": "complete"})
            self.assertEqual(len(relay.pushes), 1)
            self.assertEqual(relay.pushes[0][0][3]["text"], text)

    async def test_live_error_is_delivered_even_when_text_is_silent_marker(self):
        relay = self.relay("[SILENT]")
        await relay._finish_turn("live", relay.attached["live"], {"text": "[SILENT]", "error": "Connection failed"})
        self.assertEqual(relay.pushes[0][0][0], "error")
        self.assertEqual(relay.pushes[0][0][3]["text"], "Connection failed")
        self.assertEqual(relay.ends[0][0], ("bot-chat", "error"))

    async def test_live_meaningful_message_is_delivered(self):
        text = "The output included NO_REPLY; I need your input."
        relay = self.relay(text)
        await relay._finish_turn("live", relay.attached["live"], {"text": text})
        self.assertEqual(relay.pushes[0][0][0], "turn")
        self.assertEqual(relay.pushes[0][0][3]["text"], text)

    async def test_wire_silence_finishes_activity_without_done_push(self):
        relay = self.relay("")
        await relay._finish_turn("live", relay.attached["live"], {
            "text": "", "status": "complete", "intentional_silence": True})
        self.assertEqual(relay.ends[0][0], ("bot-chat", "done"))
        self.assertEqual(relay.pushes, [])
        relay._recent_thread.assert_not_awaited()
        self.assertIn("bot-chat", relay._turn_pushed_at)
        # A later ordinary blank completion is not deduplicated against a quiet turn.
        await relay._finish_turn("live", relay.attached["live"], {"text": "", "status": "complete"})
        self.assertEqual(relay.pushes[0][0][3]["text"], "Done")

    async def test_untrusted_or_unsuccessful_flag_does_not_suppress_completion(self):
        for payload in (
            {"text": "", "intentional_silence": True},
            {"text": "", "status": "complete", "intentional_silence": "true"},
            {"text": "", "status": "error", "intentional_silence": True, "error": "Failed"},
            {"text": "[SILENT]", "status": "interrupted", "intentional_silence": True},
            {"text": "The report is ready.", "status": "complete"},
        ):
            with self.subTest(payload=payload):
                relay = self.relay("")
                await relay._finish_turn("live", relay.attached["live"], payload)
                self.assertEqual(len(relay.pushes), 1)
                relay._recent_thread.assert_awaited_once()
                if payload.get("error"):
                    self.assertEqual(relay.pushes[0][0][0], "error")

    async def test_fallback_preserves_typed_silence_metadata_including_empty_final(self):
        for text in ("", "*NO_REPLY*", "SILENT"):
            relay = self.relay(text)
            relay.gw.messages = [
                {"role": "user", "text": '[Cronjob "Pulse" output] No change', "display_kind": "internal_notification"},
                {"role": "assistant", "text": text, "display_kind": "hidden",
                 "display_metadata": {"control_marker": "intentional_silence"}},
            ]
            self.assertEqual(await relay.check_bot_chats(), 0)
            self.assertEqual(relay.pushes, [])
            self.assertIn(("bot-chat", 4), relay._bot_chat_pushed)

    async def test_fallback_never_reuses_reply_before_latest_prompt_or_tool_final(self):
        relay = self.relay("")
        original = [
            {"role": "user", "text": '[Cronjob "Old" output] Old turn'},
            {"role": "assistant", "text": "Earlier useful reply"},
            {"role": "user", "text": '[Cronjob "New" output] New turn'},
        ]
        for tail in ([], [{"role": "assistant", "text": "", "display_kind": "hidden",
                           "display_metadata": {"control_marker": "intentional_silence"}}],
                     [{"role": "assistant", "text": "Still working", "tool_calls": [{"id": "tool"}]}]):
            relay = self.relay("")
            relay.gw.messages = original + tail
            self.assertEqual(await relay.check_bot_chats(), 0)
            self.assertEqual(relay.pushes, [])

    async def test_fallback_does_not_strip_other_hidden_rows_or_failed_markers(self):
        for metadata in ({"display_kind": "hidden"}, {"display_kind": "hidden", "display_metadata": {"control_marker": "other"}},
                         {"display_kind": "hidden", "display_metadata": {"control_marker": "intentional_silence"}, "error": "Failed"},
                         {"display_kind": "hidden", "display_metadata": {"control_marker": "intentional_silence"}, "finish_reason": "error"}):
            relay = self.relay("")
            relay.gw.messages = [
                {"role": "user", "text": '[Cronjob "Pulse" output] No change'},
                {"role": "assistant", "text": "SILENT", **metadata}]
            self.assertEqual(await relay.check_bot_chats(), 1)
            self.assertEqual(relay.pushes[0][0][3]["text"], "SILENT")


if __name__ == "__main__":
    unittest.main()
