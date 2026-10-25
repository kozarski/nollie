from tempfile import TemporaryDirectory
import unittest

from support import handoffs


class ChainTests(unittest.TestCase):
    def test_two_levels_at_most(self):
        first = handoffs.check_handoff(["default"], "scout")
        self.assertEqual((first["ok"], first["level"], first["chain"]), (True, 1, ["default", "scout"]))
        second = handoffs.check_handoff(first["chain"], "forager")
        self.assertEqual((second["ok"], second["level"]), (True, 2))
        third = handoffs.check_handoff(second["chain"], "mason")
        self.assertEqual((third["ok"], third["reason"]), (False, "too_deep"))

    def test_no_loops(self):
        for chain, to in ((["default"], "default"), (["default", "scout"], "default"), (["default", "scout"], "scout")):
            verdict = handoffs.check_handoff(chain, to)
            self.assertEqual((verdict["ok"], verdict["reason"]), (False, "loop"), (chain, to))

    def test_a_chain_needs_a_starting_bot(self):
        self.assertEqual(handoffs.check_handoff([], "scout")["reason"], "no_chain")


class ConversationTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.log = handoffs.Conversations(self.temp.name)

    def test_pauses_to_ask_after_twelve_messages_without_the_person(self):
        for count in range(1, handoffs.PAUSE_AFTER):
            result = self.log.bot_message("chat-1")
            self.assertEqual((result["ok"], result["count"]), (True, count))
        result = self.log.bot_message("chat-1")
        self.assertEqual(result, {"ok": False, "paused": True,
                                  "question": "The crew has sent 12 messages to each other without you. Should they keep going?"})
        self.assertFalse(self.log.bot_message("chat-1")["ok"])
        self.assertTrue(self.log.bot_message("chat-2")["ok"])  # counted per conversation
        self.log.person_spoke("chat-1")
        self.assertEqual(self.log.bot_message("chat-1")["count"], 1)

    def test_counts_survive_a_restart(self):
        for _ in range(5):
            self.log.bot_message("chat-1")
        again = handoffs.Conversations(self.temp.name)
        self.assertEqual(again.bot_message("chat-1")["count"], 6)

    def test_handoffs_count_and_stop_when_paused(self):
        for _ in range(handoffs.PAUSE_AFTER - 1):
            self.assertTrue(self.log.handoff("chat-1", ["default"], "scout")["ok"])
        stopped = self.log.handoff("chat-1", ["default"], "scout")
        self.assertEqual(stopped["reason"], "paused")
        self.assertEqual(self.log.handoff("chat-2", ["default", "scout"], "default")["reason"], "loop")

    def test_conversation_id_is_required(self):
        with self.assertRaises(ValueError):
            self.log.bot_message("")


if __name__ == "__main__":
    unittest.main()
