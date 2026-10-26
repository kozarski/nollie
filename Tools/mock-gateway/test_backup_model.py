"""The backup model: kept per bot in the config as Hermes keeps `fallback_providers`, and the turns that show
Hermes switching to it and back, in Hermes's own words."""
import importlib.util
import json
from pathlib import Path
import re
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("backup_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

LLAMA = {"provider": "llamacpp", "model": "llama-3.2-3b-instruct-q4_k_m"}
# agent/chat_completion_helpers.py and agent/agent_runtime_helpers.py in Hermes v0.22.2.
SWITCHED = re.compile(r"⚠️ Model fallback: (\S+) via (\S+) unavailable \(([^)]*)\); using (\S+) via (\S+)\."
                      r"( Primary retry eligible in ~(\d+) s; recovery is not guaranteed\.)?\Z")
RESTORED = re.compile(r"✅ Primary model restored: (\S+) via (\S+); fallback (\S+) via (\S+) is no longer active\.\Z")


class BackupConfigTests(unittest.TestCase):
    def setUp(self):
        mock.FALLBACKS.clear()
        self.addCleanup(mock.FALLBACKS.clear)

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def test_none_until_one_is_chosen_then_read_back_for_that_bot_only(self):
        status, body = self.request("/api/config?profile=default")
        self.assertEqual((status, body["config"]["fallback_providers"]), (200, []))
        self.assertEqual(body["config"]["approvals"], mock.CONFIG["approvals"])
        status, _ = self.request("/api/config?profile=default", "PUT", {"config": {"fallback_providers": [LLAMA]}})
        self.assertEqual(status, 200)
        self.assertEqual(self.request("/api/config?profile=default")[1]["config"]["fallback_providers"], [LLAMA])
        self.assertEqual(self.request("/api/config?profile=work")[1]["config"]["fallback_providers"], [])
        # Off: an empty list replaces it whole.
        self.request("/api/config?profile=default", "PUT", {"config": {"fallback_providers": [], "fallback_model": None}})
        self.assertEqual(self.request("/api/config?profile=default")[1]["config"]["fallback_providers"], [])

    def test_a_backup_without_a_model_is_refused_and_nothing_changes(self):
        status, _ = self.request("/api/config?profile=default", "PUT", {"config": {"fallback_providers": [{"provider": "x"}]}})
        self.assertEqual(status, 422)
        self.assertEqual(mock.FALLBACKS, {})

    def test_other_config_writes_go_on_as_before(self):
        writes = mock.COMPUTER_PREVIEW["writes"]
        status, _ = self.request("/api/config?profile=default", "PUT", {"config": {"command_allowlist": []}})
        self.assertEqual(status, 200)
        self.assertEqual(mock.COMPUTER_PREVIEW["writes"], writes + 1)
        self.assertEqual(mock.FALLBACKS, {})


class BackupTurnTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.gateway = mock.Gateway(None)
        self.sent = []

        async def event(name, sid, payload=None):
            self.sent.append((name, payload or {}))

        async def nothing(*args, **kwargs):
            return None
        self.gateway.event = event
        for name in ("begin_message", "stream_words", "report_usage", "settle"):
            setattr(self.gateway, name, nothing)
        self.session = SimpleNamespace(sid="s1")

    async def test_the_switch_is_said_in_hermess_words_with_when_it_tries_again(self):
        await self.gateway._backup_turn(self.session, "backup please")
        (notice,) = [p["text"] for name, p in self.sent if name == "status.update"]
        found = SWITCHED.fullmatch(notice)
        self.assertIsNotNone(found, notice)
        self.assertEqual((found[1], found[2], found[3], found[4], found[5]),
                         (mock.MODEL, mock.PROVIDER, "billing or quota exhausted", mock.BACKUP_MODEL, "llamacpp"))
        self.assertGreater(int(found[7]), 3600)

    async def test_and_back(self):
        await self.gateway._plan_back_turn(self.session, "plan back?")
        self.assertIsNotNone(RESTORED.fullmatch(self.sent[0][1]["text"]))

    def test_scripts_are_found_by_their_first_word(self):
        self.assertEqual(mock.Gateway._script_for("Backup test", mock.Gateway._LATE_SCRIPTS), "_backup_turn")
        self.assertEqual(mock.Gateway._script_for("plan back?", mock.Gateway._LATE_SCRIPTS), "_plan_back_turn")


if __name__ == "__main__":
    unittest.main()
