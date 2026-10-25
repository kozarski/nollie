import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("nollie_mac_plugin", Path(__file__).resolve().parents[1] / "__init__.py")
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)

ENV = {"HERMES_SESSION_PROFILE": "career", "HERMES_SESSION_PLATFORM": "api_server", "HERMES_SESSION_KEY": "agent:career:chat-7"}


def hook(tool_name, args=None, session_id="20261019_200000_abc123", attended=True):
    return plugin.on_pre_tool_call(tool_name=tool_name, args=args or {}, session_id=session_id,
                                   nobody_can_answer=lambda: not attended, session_env=ENV.get)


class PluginTests(unittest.TestCase):
    def test_other_tools_pass_untouched(self):
        self.assertIsNone(hook("web_search", attended=False))
        self.assertIsNone(hook("mcp__cua__computer_click"))

    def test_unattended_scheduled_and_unknown_runs_are_blocked(self):
        for kwargs in ({"attended": False}, {"session_id": "cron_board_20261019_070000"}, {"session_id": None},
                       {"session_id": ""}):
            result = hook("mcp__nollie_mac__mac_start", {"apps": ["Notes"]}, **kwargs)
            self.assertEqual(result, {"action": "block", "message": plugin.UNATTENDED})

    def test_a_live_chat_is_stamped_over_anything_the_model_wrote(self):
        forged = {"app": "Notes", "_nollie": {"session_id": "someone_elses_chat"}}
        result = hook("mcp__nollie_mac__mac_click", forged)
        self.assertEqual(result["action"], "modify")
        self.assertEqual(result["args"]["app"], "Notes")
        self.assertEqual(result["args"]["_nollie"], {"session_id": "20261019_200000_abc123", "chat": "agent:career:chat-7",
                                                     "profile": "career", "platform": "api_server"})
        self.assertEqual(forged["_nollie"], {"session_id": "someone_elses_chat"})

    def test_the_main_bot_is_default(self):
        # A gateway session of the main bot has no profile name.
        result = plugin.on_pre_tool_call(tool_name="mcp__nollie_mac__mac_start", args={}, session_id="s1",
                                         nobody_can_answer=lambda: False, session_env={}.get)
        self.assertEqual(result["args"]["_nollie"]["profile"], "default")

    def test_doubt_counts_as_nobody_there(self):
        # Outside Hermes the approval context can't be imported: that is unattended.
        self.assertTrue(plugin._nobody_can_answer())

    def test_registers_one_hook(self):
        hooks = []

        class Context:
            def register_hook(self, name, callback):
                hooks.append((name, callback))

        plugin.register(Context())
        self.assertEqual(hooks, [("pre_tool_call", plugin.on_pre_tool_call)])


if __name__ == "__main__":
    unittest.main()
