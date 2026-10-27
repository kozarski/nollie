import fcntl
import importlib.util
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "papertrail_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from papertrail_test_package import followup_tools, papertrail, private_bots, service

install_spec = importlib.util.spec_from_file_location("papertrail_installer", ROOT / "install.py")
installer = importlib.util.module_from_spec(install_spec)
install_spec.loader.exec_module(installer)

try:
    import yaml
except ImportError:
    yaml = None
try:
    import fastapi
    from fastapi.testclient import TestClient
except (ImportError, RuntimeError):
    fastapi = TestClient = None

HERMES_SOURCE = Path(os.environ.get("NOLLIE_HERMES_SOURCE", Path.home() / ".hermes" / "hermes-agent"))
HERMES_PYTHON = os.environ.get("NOLLIE_HERMES_PYTHON", "")
SUBSCRIPTION = "claude-subscription-direct"
# 15:00 local on 20 Oct 2026: the tests read in the Mac's own time zone, as the route does.
NOW = datetime(2026, 10, 20, 15, 0).timestamp()
TODAY = datetime(2026, 10, 20).timestamp()
SECRETS = ("secret-prompt", "secret-reply", "secret-query", "secret-page", "secretpass", "secret-token",
           "/v1/secret-path", "secret-result", "secret-error")


class Clock:
    def __init__(self, now=NOW):
        self.now = now

    def __call__(self):
        return self.now


def usage(i=0, o=0, cache=0, think=0):
    return {"input_tokens": i, "output_tokens": o, "cache_read_tokens": cache, "cache_write_tokens": 7,
            "reasoning_tokens": think, "request_count": 1}


def lines(root):
    return [json.loads(line) for path in sorted(root.glob("*.jsonl")) for line in path.read_text().splitlines()
            if line.startswith("{")]


class RouteRuleTests(unittest.TestCase):
    def test_route_rule_decides_by_provider_and_host_together(self):
        table = [
            (SUBSCRIPTION, f"process://{SUBSCRIPTION}", "online"),
            ("llamacpp", "http://127.0.0.1:18434/v1", "mac"),
            ("custom", "http://localhost:8080/v1", "mac"),
            ("custom", "http://127.8.9.1/v1", "mac"),
            ("custom", "http://[::1]:11434", "mac"),
            ("custom", "http://0.0.0.0:1234", "mac"),
            ("custom", "http://192.168.1.20:11434/v1", "network"),
            ("custom", "http://10.0.0.5/v1", "network"),
            ("custom", "http://172.20.1.1/v1", "network"),
            ("custom", "http://100.64.0.7:8080/v1", "network"),
            ("custom", "http://100.101.102.103/v1", "network"),
            ("custom", "http://169.254.3.4/v1", "network"),
            ("custom", "http://studio.local:1234/v1", "network"),
            ("custom", "http://gpubox:8000/v1", "network"),
            ("ollama", "", "mac"),
            ("lmstudio", None, "mac"),
            ("mlx", "", "mac"),
            ("anthropic", "", "online"),
            ("", "", "online"),
            ("anthropic", "https://api.anthropic.com/v1", "online"),
            ("openrouter", "https://openrouter.ai/api/v1", "online"),
            ("ollama", "https://ollama.com/v1", "online"),
            ("llamacpp", "process://runtime", "mac"),
            ("llamacpp", "unix:///tmp/llama.sock", "mac"),
            ("ollama", "ws://127.0.0.1:11434", "mac"),
            ("llamacpp", "ws://gpu.example.com", "online"),
            ("ollama", "grpc://remote.example.com:443", "online"),
            ("mlx", "ws://studio.local:9000", "network"),
            ("custom", "ws://127.0.0.1:9000", "online"),
            ("lmstudio", "ws:///no-host", "online"),
            ("custom", "http://100.128.0.1/v1", "online"),
            ("custom", "http://[not-an-address/v1", "online"),
            ("custom", "http://host:notaport/v1", "network"),
        ]
        for provider, base_url, expected in table:
            self.assertEqual(papertrail.route(provider, base_url), expected, (provider, base_url))

    def test_host_keeps_scheme_host_and_port_only(self):
        self.assertEqual(papertrail.host("https://user:secretpass@api.example.com:8443/v1/chat?token=secret-token"),
                         "https://api.example.com:8443")
        self.assertEqual(papertrail.host("HTTP://Studio.Local/v1"), "http://studio.local")
        self.assertEqual(papertrail.host("http://[::1]:8080/v1"), "http://[::1]:8080")
        for url in (f"process://{SUBSCRIPTION}", "", None, "ftp://files.example.com", "localhost:8080",
                    "http://bad host/"):
            self.assertIsNone(papertrail.host(url), url)


class RecorderTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name) / "career"
        self.home.mkdir()
        self.clock = Clock()
        self.recorder = papertrail.Recorder(self.home, clock=self.clock)
        self.root = self.home / "nollie-workflow" / "papertrail"

    def fire_every_hook(self):
        secret_url = "https://u:secretpass@api.example.com/v1/secret-path?token=secret-token"
        self.recorder.post_api_request(
            session_id="s-1", turn_id="t-1", api_request_id="r-1", model="claude-sonnet-5-5", provider=SUBSCRIPTION,
            base_url=f"process://{SUBSCRIPTION}", ended_at=NOW - 60, usage=usage(1200, 340, 9000),
            request_messages=[{"role": "user", "content": "secret-prompt"}], response={"content": "secret-reply"},
            assistant_message=SimpleNamespace(content="secret-reply"), platform="api_server")
        self.recorder.api_request_error(
            session_id="s-1", turn_id="t-1", model="gpt-6", provider="openrouter", base_url=secret_url,
            ended_at=NOW - 50, error={"type": "Timeout", "message": "secret-error"}, request={"body": "secret-prompt"})
        self.recorder.post_auxiliary_call(
            session_id="s-1", turn_id="t-1", aux_task="title_generation", model="qwen3", provider="llamacpp",
            base_url="http://127.0.0.1:18434/v1", ended_at=NOW - 40, usage=usage(50, 8), error="secret-error",
            response={"content": "secret-reply"})
        self.recorder.post_tool_call(tool_name="web_search", args={"query": "secret-query"}, result="secret-result",
                                     status="ok", session_id="s-1", turn_id="t-1", tool_call_id="c-1")
        self.recorder.post_tool_call(tool_name="web_extract", args={"urls": ["https://secret-page.example/a",
                                                                         "https://secret-page.example/b"]},
                                     result="secret-result", status="error", session_id="s-1", turn_id="t-1")
        self.recorder.post_tool_call(tool_name="terminal", args={"command": "secret-prompt"}, status="ok",
                                     session_id="s-1", turn_id="t-1")
        self.recorder.post_tool_call(tool_name="web_search", args={"query": "secret-query"}, status="blocked",
                                     session_id="s-1", turn_id="t-1")
        self.assertTrue(self.recorder.flush())

    @unittest.skipUnless(yaml, "the search service is read from YAML")
    def test_recorder_writes_one_wordless_line_per_call(self):
        (self.home / "config.yaml").write_text("web:\n  backend: firecrawl\n  search_backend: exa\n")
        self.fire_every_hook()
        text = "".join(path.read_text() for path in self.root.glob("*.jsonl"))
        for secret in SECRETS:
            self.assertNotIn(secret, text)
        recorded = lines(self.root)
        self.assertEqual(len(recorded), 5)
        self.assertEqual(recorded[0], {
            "v": 1, "at": NOW - 60, "route": "online", "source": "model", "provider": SUBSCRIPTION, "host": None,
            "model": "claude-sonnet-5-5", "task": "", "tool": "", "turn": "t-1", "session": "s-1",
            "in": 1200, "out": 340, "cache": 9000, "think": 0, "searches": 0, "pages": 0, "images": 0})
        error, helper, search, extract = recorded[1:]
        self.assertEqual((error["route"], error["host"], error["in"]), ("online", "https://api.example.com", 0))
        self.assertEqual((helper["route"], helper["source"], helper["task"], helper["host"]),
                         ("mac", "helper", "title_generation", "http://127.0.0.1:18434"))
        self.assertEqual((search["source"], search["tool"], search["provider"], search["searches"], search["at"]),
                         ("tool", "web_search", "exa", 1, NOW))
        self.assertEqual((extract["pages"], extract["provider"], extract["route"]), (2, "", "online"))
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        for path in self.root.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, path.name)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["2026-10-20.jsonl", "papertrail.lock"])

    def test_web_extract_counts_only_the_pages_hermes_reads(self):
        self.recorder.post_tool_call(tool_name="web_extract", args={"urls": [f"https://e.example/{n}" for n in range(7)]},
                                     status="ok", turn_id="t-1")
        for urls in ("https://e.example/a", None, []):
            self.recorder.post_tool_call(tool_name="web_extract", args={"urls": urls}, status="ok", turn_id="t-2")
        self.recorder.post_tool_call(tool_name="web_extract", args="not a dict", status="ok", turn_id="t-3")
        self.recorder.flush()
        self.assertEqual([(line["turn"], line["pages"]) for line in lines(self.root)], [("t-1", 5)])

    def test_hooks_return_at_once_while_another_process_holds_the_lock(self):
        lock = os.open(self.root / "papertrail.lock", os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        started = time.monotonic()
        for n in range(3):
            self.recorder.post_auxiliary_call(turn_id="t-1", aux_task="compression", provider="anthropic",
                                              base_url="https://api.anthropic.com", ended_at=NOW - n, usage=usage(5))
        self.assertLess(time.monotonic() - started, 0.2)
        self.assertEqual(lines(self.root), [])
        fcntl.flock(lock, fcntl.LOCK_UN)
        self.assertTrue(self.recorder.flush())
        self.assertEqual(len(lines(self.root)), 3, "no call is lost while the lock is busy")

    @unittest.skipUnless(yaml, "the search service is read from YAML")
    def test_search_service_falls_back_to_the_shared_backend_and_follows_config_changes(self):
        config = self.home / "config.yaml"
        config.write_text("web:\n  backend: parallel\n")
        self.assertEqual(self.recorder.search_service(), "parallel")
        config.write_text("web:\n  search_backend: exa\n  backend: parallel\n")
        os.utime(config, ns=(1, 1))
        self.assertEqual(self.recorder.search_service(), "exa")
        config.unlink()
        self.assertEqual(self.recorder.search_service(), "")

    def test_a_linked_folder_or_file_is_refused(self):
        with TemporaryDirectory() as elsewhere:
            self.root.rmdir()
            self.root.symlink_to(elsewhere)
            self.fire_every_hook()
            self.assertEqual(os.listdir(elsewhere), [])
            self.root.unlink()
            self.root.mkdir(mode=0o700)
            outside = Path(elsewhere) / "outside.jsonl"
            outside.write_text("")
            (self.root / "2026-10-20.jsonl").symlink_to(outside)
            self.fire_every_hook()
            self.assertEqual(outside.read_text(), "")
            self.assertEqual((self.root / "last_error").read_text(), "LinkedPath\n")

    def test_failures_never_reach_hermes(self):
        shutil.rmtree(self.home / "nollie-workflow")
        (self.home / "nollie-workflow").write_text("not a folder")
        self.fire_every_hook()  # nothing raised
        self.recorder.post_api_request(usage="nonsense", ended_at="later", provider=None, base_url=12)
        self.assertTrue(self.recorder.flush())

    def test_a_damaged_line_is_skipped_and_the_next_line_starts_clean(self):
        day = self.root / "2026-10-20.jsonl"
        day.write_text('{"v":1,"at":1,"route":"online"}\nnot json\n{"v":1,"at":')
        day.chmod(0o600)
        self.recorder.post_api_request(turn_id="t-9", provider="anthropic", base_url="https://api.anthropic.com",
                                       ended_at=NOW - 5, usage=usage(10, 2))
        self.recorder.flush()
        self.assertTrue(day.read_text().endswith('{"v":1,"at":\n' + day.read_text().splitlines()[-1] + "\n"))
        answer = papertrail.read(self.home, "career", 7, now=NOW, provider_name=lambda p: None)
        self.assertEqual([entry["id"] for entry in answer["entries"]], ["t-9"])

    def test_first_write_of_a_day_prunes_files_older_than_35_days(self):
        for days in (40, 36, 35, 1):
            name = (datetime(2026, 10, 20) - timedelta(days=days)).strftime("%Y-%m-%d") + ".jsonl"
            (self.root / name).write_text("")
        (self.root / "notes.txt").write_text("kept")
        self.recorder.post_tool_call(tool_name="image_generate", status="ok", turn_id="t-1")
        self.recorder.flush()
        self.assertEqual(sorted(p.name for p in self.root.glob("*.jsonl")),
                         ["2026-09-15.jsonl", "2026-10-19.jsonl", "2026-10-20.jsonl"])
        self.assertTrue((self.root / "notes.txt").exists())
        (self.root / "2026-09-01.jsonl").write_text("")
        self.recorder.post_tool_call(tool_name="image_generate", status="ok", turn_id="t-2")
        self.recorder.flush()
        self.assertTrue((self.root / "2026-09-01.jsonl").exists(), "only the first write of a day prunes")
        self.clock.now += 86400
        self.recorder.post_tool_call(tool_name="image_generate", status="ok", turn_id="t-3")
        self.recorder.flush()
        self.assertFalse((self.root / "2026-09-01.jsonl").exists())


class ReaderTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.clock = Clock()
        self.recorder = papertrail.Recorder(self.home, clock=self.clock)

    def model(self, at, turn="", session="s-1", provider=SUBSCRIPTION, base_url=f"process://{SUBSCRIPTION}",
              model="claude-sonnet-5-5", **tokens):
        self.recorder.post_api_request(session_id=session, turn_id=turn, model=model, provider=provider,
                                       base_url=base_url, ended_at=at, usage=usage(**tokens))
        self.recorder.flush()

    def helper(self, at, task, turn="", session="s-1", provider="llamacpp", base_url="http://127.0.0.1:18434/v1"):
        self.recorder.post_auxiliary_call(session_id=session, turn_id=turn, aux_task=task, model="qwen3",
                                          provider=provider, base_url=base_url, ended_at=at, usage=usage(5, 1))
        self.recorder.flush()

    def tool(self, at, name, turn="", **args):
        self.clock.now = at
        self.recorder.post_tool_call(tool_name=name, args=args, status="ok", session_id="s-1", turn_id=turn)
        self.clock.now = NOW
        self.recorder.flush()

    def read(self, days=7, **kw):
        return papertrail.read(self.home, "career", days, now=NOW,
                               provider_name=kw.get("names", lambda p: {"anthropic": "Anthropic"}.get(p)))

    @unittest.skipUnless(yaml, "the search service is read from YAML")
    def test_calls_group_into_entries_and_local_replies_are_only_counted(self):
        (self.home / "config.yaml").write_text("web:\n  search_backend: exa\n")
        self.model(NOW - 600, "t-42", i=18000, o=900, cache=52000)
        self.helper(NOW - 590, "title_generation", "t-42", provider="anthropic", base_url="https://api.anthropic.com")
        self.helper(NOW - 580, "compression", "t-42")
        self.tool(NOW - 570, "web_search", "t-42", query="q")
        self.tool(NOW - 560, "web_extract", "t-42", urls=["a", "b", "c"])
        self.model(NOW - 500, "t-43", provider="llamacpp", base_url="http://127.0.0.1:18434/v1", i=400, o=20)
        self.helper(NOW - 490, "title_generation", "t-43")
        self.model(NOW - 86400, "t-1", provider="custom", base_url="http://192.168.1.9:8000/v1", model="m", i=5)
        self.model(NOW - 2 * 86400, "t-0", provider="ollama", base_url="", i=5)
        answer = self.read()
        self.assertEqual(answer["now"], int(NOW))
        self.assertEqual(answer["today_starts_at"], int(TODAY))
        self.assertEqual(answer["since"], int(datetime(2026, 10, 14).timestamp()))
        self.assertEqual(answer["recording_since"], int(datetime(2026, 10, 18).timestamp()))
        self.assertEqual(answer["stayed"], {"today": 1, "window": 2})
        self.assertEqual(answer["left"], {"today": 1, "window": 2})
        self.assertEqual(answer["more"], 0)
        first, second = answer["entries"]
        self.assertEqual(first, {
            "id": "t-42", "at": int(NOW - 560), "started_at": int(NOW - 600), "route": "online",
            "provider": SUBSCRIPTION, "provider_name": None, "host": None, "model": "claude-sonnet-5-5",
            "calls": 4, "helpers": ["title_generation"], "services": ["exa"], "input_tokens": 18005,
            "output_tokens": 901, "cache_read_tokens": 52000, "reasoning_tokens": 0,
            "searches": 1, "pages": 3, "images": 0, "icloud_notes": 0, "payments": [], "local_reads": [],
            "connections": []})
        self.assertEqual((second["id"], second["route"], second["host"], second["provider"]),
                         ("t-1", "network", "http://192.168.1.9:8000", "custom"))

    def test_the_largest_online_route_by_tokens_names_the_entry(self):
        self.model(NOW - 100, "t-1", provider="anthropic", base_url="https://api.anthropic.com", model="a", i=100)
        self.model(NOW - 90, "t-1", provider="openrouter", base_url="https://openrouter.ai/api/v1", model="b", i=60)
        self.model(NOW - 80, "t-1", provider="openrouter", base_url="https://openrouter.ai/api/v1", model="b", i=60)
        self.model(NOW - 70, "t-1", provider="custom", base_url="http://10.0.0.2/v1", model="c", i=9000)
        entry = self.read()["entries"][0]
        self.assertEqual((entry["provider"], entry["host"], entry["model"], entry["calls"]),
                         ("openrouter", "https://openrouter.ai", "b", 4))
        self.model(NOW - 60, "t-1", provider="anthropic", base_url="https://api.anthropic.com", model="a", i=30)
        entry = self.read()["entries"][0]
        self.assertEqual((entry["provider"], entry["provider_name"], entry["route"]), ("anthropic", "Anthropic", "online"))

    def test_an_entry_where_only_tools_left_has_no_model_route(self):
        self.model(NOW - 100, "t-1", provider="ollama", base_url="http://localhost:11434", i=10)
        self.tool(NOW - 90, "x_search", "t-1")
        self.tool(NOW - 80, "browser_navigate", "t-1", url="https://example.com")
        entry = self.read()["entries"][0]
        self.assertEqual((entry["provider"], entry["host"], entry["model"], entry["provider_name"]),
                         (None, None, None, None))
        self.assertEqual((entry["services"], entry["searches"], entry["pages"], entry["calls"], entry["input_tokens"]),
                         (["xai"], 1, 1, 2, 0))

    def test_a_network_model_beside_an_online_search_is_named_by_the_search(self):
        self.model(NOW - 100, "t-1", provider="custom", base_url="http://192.168.1.9:8000/v1", model="m", i=500)
        self.tool(NOW - 90, "web_search", "t-1")
        entry = self.read()["entries"][0]
        self.assertEqual((entry["route"], entry["provider"], entry["host"], entry["model"]),
                         ("online", None, None, None))
        self.assertEqual((entry["searches"], entry["input_tokens"]), (1, 500))

    def test_notes_sealed_for_the_iphone_show_as_icloud_without_their_words(self):
        self.clock.now = NOW - 100
        self.assertTrue(self.recorder.icloud("card"))
        self.clock.now = NOW - 50
        self.assertTrue(self.recorder.icloud("reply"))
        self.assertFalse(self.recorder.icloud("secret-reply"))
        self.clock.now = NOW
        self.recorder.flush()
        lines = [json.loads(line) for line in next(self.home.glob("nollie-workflow/papertrail/*.jsonl")).read_text().splitlines()]
        self.assertEqual([(l["route"], l["source"], l["tool"]) for l in lines], [("icloud", "away", "card"), ("icloud", "away", "reply")])
        entry = self.read()["entries"][0]
        self.assertEqual((entry["route"], entry["icloud_notes"], entry["calls"], entry["provider"]), ("icloud", 2, 2, None))
        self.assertEqual(entry["why"]["origin"], "chat")
        # A model call in the same window still names the entry by where the words went to be answered.
        self.model(NOW - 40, "t-9", i=10)
        self.assertEqual({e["route"] for e in self.read()["entries"]}, {"icloud", "online"})

    def test_a_mac_session_keeps_the_apps_and_counts_only(self):
        self.clock.now = NOW - 100
        self.assertTrue(self.recorder.mac_session(["Notes", "Mail<script>", 7, "x" * 90], 3, looks=4, session="s-1"))
        self.assertFalse(self.recorder.mac_session([], 1))
        self.assertFalse(self.recorder.mac_session(["Notes"], True))
        self.clock.now = NOW
        self.recorder.flush()
        line = json.loads(next(self.home.glob("nollie-workflow/papertrail/*.jsonl")).read_text().splitlines()[0])
        self.assertEqual((line["route"], line["source"], line["tool"], line["apps"], line["actions"], line["looks"],
                          line["screenshots_left"]), ("mac", "tool", "mac_session", ["Notes", "Mailscript", "x" * 60], 3, 4, 0))
        answer = self.read()
        self.assertEqual(answer["mac_sessions"], [{"at": int(NOW - 100), "apps": ["Notes", "Mailscript", "x" * 60],
                                                   "actions": 3, "looks": 4, "screenshots_left": 0}])
        self.assertEqual((answer["entries"], answer["stayed"]["today"]), ([], 1))

    def test_calls_without_a_turn_group_by_session_route_and_ten_minutes(self):
        start = TODAY + 3 * 3600
        self.helper(start + 10, "curator", provider="anthropic", base_url="https://api.anthropic.com")
        self.helper(start + 300, "curator", provider="anthropic", base_url="https://api.anthropic.com")
        self.helper(start + 400, "curator", session="s-2", provider="anthropic", base_url="https://api.anthropic.com")
        self.helper(start + 700, "curator", provider="anthropic", base_url="https://api.anthropic.com")
        self.helper(start + 20, "curator")
        answer = self.read()
        self.assertEqual(sorted(entry["calls"] for entry in answer["entries"]), [1, 1, 2])
        self.assertTrue(all(entry["id"].startswith("w-") for entry in answer["entries"]))
        self.assertEqual(answer["stayed"], {"today": 1, "window": 1})
        self.assertEqual(answer, self.read(), "ids are stable")

    def test_at_most_200_entries_newest_first_and_more_counts_the_rest(self):
        for n in range(205):
            self.model(NOW - 5000 + n, f"t-{n:03}", i=1)
        answer = self.read()
        self.assertEqual(len(answer["entries"]), 200)
        self.assertEqual(answer["more"], 5)
        self.assertEqual(answer["left"], {"today": 205, "window": 205})
        self.assertEqual(answer["entries"][0]["id"], "t-204")
        self.assertEqual(answer["entries"][-1]["id"], "t-005")

    def test_the_window_starts_at_local_midnight_days_before_today(self):
        self.model(datetime(2026, 10, 14, 0, 30).timestamp(), "t-in", i=1)
        self.model(datetime(2026, 10, 13, 23, 30).timestamp(), "t-out", i=1)
        self.assertEqual([entry["id"] for entry in self.read()["entries"]], ["t-in"])
        self.assertEqual([entry["id"] for entry in self.read(days=1)["entries"]], [])
        self.assertEqual(len(self.read(days=35)["entries"]), 2)

    @unittest.skipUnless(hasattr(time, "tzset"), "needs time.tzset")
    def test_tomorrow_starts_at_the_next_local_midnight_on_a_clock_change_day(self):
        saved = os.environ.get("TZ")
        os.environ["TZ"] = "America/Los_Angeles"
        time.tzset()
        try:
            now = datetime(2026, 11, 1, 22, 30).timestamp()  # Clocks went back at 02:00: a 25-hour day.
            answer = papertrail.read(self.home, "career", 7, now=now, provider_name=lambda p: None)
            self.assertEqual(answer["tomorrow_starts_at"] - answer["today_starts_at"], 90000)
            self.assertEqual(answer["today_starts_at"], int(datetime(2026, 11, 1).timestamp()))
        finally:
            if saved is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = saved
            time.tzset()

    def test_provider_names_come_from_hermes_without_the_network(self):
        asked = []

        def get_provider(name, allow_network=True):
            asked.append(allow_network)
            if name == "broken":
                raise RuntimeError("catalog unavailable")
            return {"anthropic": SimpleNamespace(name="Anthropic"), "openrouter": SimpleNamespace(name="openrouter")}.get(name)

        with patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(),
                                        "hermes_cli.providers": SimpleNamespace(get_provider=get_provider)}):
            names = [papertrail._hermes_provider_name(p) for p in ("anthropic", "openrouter", "unknown", "broken")]
        self.assertEqual(names, ["Anthropic", None, None, None])
        self.assertEqual(set(asked), {False})

    def test_a_missing_folder_reads_as_empty(self):
        answer = papertrail.read(self.home / "elsewhere", "career", 7, now=NOW)
        self.assertEqual((answer["entries"], answer["recording_since"], answer["left"]),
                         ([], None, {"today": 0, "window": 0}))


@unittest.skipUnless(fastapi and TestClient, "FastAPI and its test client are available in the Hermes runtime")
class DoorLineTests(unittest.TestCase):
    """Lines Nollie Runtime's door writes beside the add-on's: one per connection."""

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.clock = Clock()
        self.recorder = papertrail.Recorder(self.home, clock=self.clock)
        self.root = self.home / "nollie-workflow" / "papertrail"

    def door(self, at, host, kind="hermes", port=443, route="online", **extra):
        line = {"v": 1, "at": at, "route": route, "source": "door", "kind": kind, "host": host, "port": port, **extra}
        day = datetime.fromtimestamp(at).date().isoformat()
        with open(self.root / f"{day}.jsonl", "a") as handle:
            handle.write(json.dumps(line) + "\n")

    def model(self, at, turn, provider="ollama", base_url="http://127.0.0.1:11434"):
        self.recorder.post_api_request(session_id="s-1", turn_id=turn, model="m", provider=provider,
                                       base_url=base_url, ended_at=at, usage=usage(10, 2))
        self.recorder.flush()

    def read(self):
        return papertrail.read(self.home, "career", 7, now=NOW, provider_name=lambda p: None)

    def test_a_connection_joins_the_reply_it_happened_in(self):
        self.model(NOW - 600, "t-1", provider=SUBSCRIPTION, base_url=f"process://{SUBSCRIPTION}")
        self.model(NOW - 590, "t-1", provider=SUBSCRIPTION, base_url=f"process://{SUBSCRIPTION}")
        self.door(NOW - 598, "api.anthropic.com", kind="model")
        self.door(NOW - 596, "api.anthropic.com", kind="model")
        self.door(NOW - 594, "pypi.org", kind="terminal")
        answer = self.read()
        self.assertEqual(answer["left"]["window"], 1)
        entry = answer["entries"][0]
        self.assertEqual(entry["id"], "t-1")
        self.assertEqual(entry["calls"], 2, "connections are not model calls")
        self.assertEqual(entry["connections"], [
            {"host": "api.anthropic.com", "port": 443, "kind": "model", "route": "online", "count": 2},
            {"host": "pypi.org", "port": 443, "kind": "terminal", "route": "online", "count": 1}])

    def test_a_reply_on_this_mac_that_connected_out_is_listed(self):
        self.model(NOW - 300, "t-2")
        self.door(NOW - 299, "github.com", kind="terminal")
        answer = self.read()
        self.assertEqual(answer["stayed"]["window"], 0)
        entry = answer["entries"][0]
        self.assertEqual((entry["id"], entry["route"], entry["provider"]), ("t-2", "online", None))
        self.assertEqual(entry["connections"][0]["host"], "github.com")

    def test_connections_outside_a_reply_group_by_hour(self):
        self.model(NOW - 7200, "t-3")
        self.door(NOW - 3000, "models.example.com")
        self.door(NOW - 2990, "models.example.com")
        self.door(NOW - 2980, "192.168.1.20", kind="mcp", port=8080, route="network")
        answer = self.read()
        alone = [entry for entry in answer["entries"] if entry["id"].startswith("w-")]
        self.assertEqual(len(alone), 1)
        self.assertEqual(alone[0]["route"], "online")
        self.assertEqual([(c["host"], c["count"]) for c in alone[0]["connections"]],
                         [("models.example.com", 2), ("192.168.1.20", 1)])
        self.assertNotIn("why", alone[0])
        self.assertEqual(answer["stayed"]["window"], 1, "the reply itself stayed on this Mac")

    def test_damaged_and_local_door_lines_are_skipped(self):
        self.door(NOW - 100, "localhost", route="mac")
        self.door(NOW - 99, "bad host!")
        self.door(NOW - 98, "example.com", port=0)
        self.door(NOW - 97, "example.com", port=True)
        self.door(NOW - 96, "example.com", kind="whatever")
        entries = self.read()["entries"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["connections"],
                         [{"host": "example.com", "port": 443, "kind": "program", "route": "online", "count": 1}])

    def test_door_lines_keep_no_words(self):
        self.door(NOW - 50, "example.com", path="/secret", query="q=private", body="hello")
        entry = self.read()["entries"][0]
        self.assertNotIn("secret", json.dumps(entry))
        self.assertNotIn("private", json.dumps(entry))


class WhyTests(unittest.TestCase):
    """Why each entry went: what started the work, how much of the chat went, the backup model and the
    person's answers. Ids and short names only, and nothing made up for lines kept before."""

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.now = {"origin": "chat", "platform": "telegram"}
        self.recorder = papertrail.Recorder(self.home, clock=Clock(), context=lambda: dict(self.now))
        self.root = self.home / "nollie-workflow" / "papertrail"

    def model(self, at, turn, provider=SUBSCRIPTION, base_url=f"process://{SUBSCRIPTION}", messages=12, **extra):
        self.recorder.post_api_request(session_id="s-1", turn_id=turn, model="m", provider=provider,
                                       base_url=base_url, ended_at=at, usage=usage(100, 10), message_count=messages,
                                       request_messages=[{"content": "secret-prompt"}], **extra)
        self.assertTrue(self.recorder.flush())

    def read(self, **kw):
        return papertrail.read(self.home, "career", 7, now=NOW, provider_name=lambda p: None, **kw)

    def test_a_chat_says_where_it_came_from_and_how_much_of_it_went(self):
        self.model(NOW - 60, "t-1", messages=12)
        self.model(NOW - 50, "t-1", messages=14)
        [line, _] = lines(self.root)
        self.assertEqual({k: line[k] for k in ("origin", "platform", "messages", "backup")},
                         {"origin": "chat", "platform": "telegram", "messages": 12, "backup": False})
        self.assertNotIn("secret-prompt", json.dumps(lines(self.root)))
        [entry] = self.read()["entries"]
        self.assertEqual(entry["why"], {"origin": "chat", "task": None, "platform": "telegram", "messages": 14,
                                        "backup": False, "approvals": []})

    def test_the_chat_app_comes_from_hermes_when_the_context_has_none(self):
        self.now = {"origin": "chat", "platform": ""}
        self.model(NOW - 60, "t-1", platform="Discord")
        self.model(NOW - 50, "t-2", platform="not a name!")
        entries = {e["id"]: e for e in self.read()["entries"]}
        self.assertEqual((entries["t-1"]["why"]["platform"], entries["t-2"]["why"]["platform"]), ("discord", None))

    def test_a_schedule_or_board_task_is_named_from_titles_read_now(self):
        self.now = {"origin": "schedule", "job": "3f2a9c"}
        self.model(NOW - 60, "t-1")
        self.now = {"origin": "board", "board": "t_77"}
        self.model(NOW - 50, "t-2")
        self.now = {"origin": "helper"}
        self.model(NOW - 40, "t-3")
        self.now = {"origin": "schedule", "job": "gone"}
        self.model(NOW - 30, "t-4")
        text = "".join(path.read_text() for path in self.root.glob("*.jsonl"))
        self.assertNotIn("Morning prices", text)  # Names are never kept in the record.
        titles = {("schedule", "3f2a9c"): "Morning prices", ("board", "t_77"): "Draft the report"}
        whys = {e["id"]: e["why"] for e in self.read(titles=titles)["entries"]}
        self.assertEqual((whys["t-1"]["origin"], whys["t-1"]["task"]), ("schedule", "Morning prices"))
        self.assertEqual((whys["t-2"]["origin"], whys["t-2"]["task"]), ("board", "Draft the report"))
        self.assertEqual((whys["t-3"]["origin"], whys["t-3"]["task"]), ("helper", None))
        self.assertEqual((whys["t-4"]["origin"], whys["t-4"]["task"]), ("schedule", None))

    @unittest.skipUnless(yaml, "the bot's models are read from YAML")
    def test_a_call_the_backup_model_answered_says_so(self):
        (self.home / "config.yaml").write_text(
            "model:\n  provider: claude-subscription-direct\n  default: claude\n"
            "fallback_providers:\n  - provider: openrouter\n    model: gpt\n")
        self.model(NOW - 60, "t-1")
        self.model(NOW - 50, "t-2", provider="openrouter", base_url="https://openrouter.ai/api/v1")
        # A provider that is neither the main one nor a backup is not called a backup.
        self.model(NOW - 40, "t-3", provider="anthropic", base_url="https://api.anthropic.com")
        whys = {e["id"]: e["why"]["backup"] for e in self.read()["entries"]}
        self.assertEqual(whys, {"t-1": False, "t-2": True, "t-3": False})

    def test_the_persons_answers_in_a_turn_are_kept_with_it(self):
        self.model(NOW - 60, "t-1")
        self.recorder.post_approval_response(choice="once", pattern_key="nollie-ask-first:send:ab12",
                                             pattern_keys=["nollie-ask-first:send:ab12"], turn_id="t-1",
                                             session_key="s-1", command="secret-prompt", description="secret-reply")
        self.recorder.post_approval_response(choice="always", pattern_key="git push", turn_id="t-1")
        # Nobody answered, or no turn to explain: nothing kept.
        self.recorder.post_approval_response(choice="timeout", pattern_key="x", turn_id="t-1")
        self.recorder.post_approval_response(choice="cancelled", pattern_key="x", turn_id="t-1")
        self.recorder.post_approval_response(choice="once", pattern_key="x", turn_id="")
        # An answer in a turn that stayed on this Mac neither lists nor counts it twice.
        self.recorder.post_approval_response(choice="deny", pattern_key="nollie-ask-first:delete:cd34", turn_id="t-9")
        self.assertTrue(self.recorder.flush())
        recorded = lines(self.root)
        self.assertEqual([l.get("choice") for l in recorded if l["source"] == "approval"], ["once", "always", "deny"])
        self.assertNotIn("secret", json.dumps(recorded))
        answer = self.read()
        [entry] = answer["entries"]
        self.assertEqual(entry["why"]["approvals"], [{"at": int(NOW), "choice": "once", "ask": "send"},
                                                     {"at": int(NOW), "choice": "always", "ask": None}])
        self.assertEqual(entry["calls"], 1)
        self.assertEqual(answer["stayed"], {"today": 0, "window": 0})

    def test_lines_kept_before_reasons_were_recorded_have_no_why(self):
        old = papertrail.Recorder(self.home, clock=Clock())  # As 1.0 registered it: no context.
        old.post_api_request(session_id="s-1", turn_id="t-old", provider="anthropic",
                             base_url="https://api.anthropic.com", ended_at=NOW - 100, usage=usage(10, 2))
        self.assertTrue(old.flush())
        self.assertNotIn("origin", lines(self.root)[0])
        self.model(NOW - 60, "t-new")
        entries = {e["id"]: e for e in self.read()["entries"]}
        self.assertNotIn("why", entries["t-old"])
        self.assertEqual(entries["t-new"]["why"]["origin"], "chat")

    def test_a_failing_context_still_records_the_call(self):
        def broken():
            raise RuntimeError("no context")
        self.recorder.context = broken
        self.model(NOW - 60, "t-1")
        [line] = lines(self.root)
        self.assertNotIn("origin", line)
        self.assertEqual(line["in"], 100)

    def test_hermes_context_reads_the_run_without_files(self):
        execution = SimpleNamespace(job_id="3f2a9c", execution_id="e-1")
        ctx = SimpleNamespace(current_cron_execution=lambda: execution)
        self.assertEqual(papertrail.hermes_context(ctx)(), {"origin": "schedule", "job": "3f2a9c"})
        ctx = SimpleNamespace(current_cron_execution=lambda: None)
        with patch.dict(os.environ, {"HERMES_KANBAN_TASK": "t_9"}):
            self.assertEqual(papertrail.hermes_context(ctx)(), {"origin": "board", "board": "t_9"})
        env = {k: v for k, v in os.environ.items() if not k.startswith("HERMES_")}
        with patch.dict(os.environ, dict(env, HERMES_CRON_SESSION="1"), clear=True):
            self.assertEqual(papertrail.hermes_context(ctx)(), {"origin": "helper"})
        with patch.dict(os.environ, dict(env, HERMES_SESSION_PLATFORM="Telegram"), clear=True):
            self.assertEqual(papertrail.hermes_context(ctx)(), {"origin": "chat", "platform": "telegram"})
        with patch.dict(os.environ, env, clear=True):
            self.assertEqual(papertrail.hermes_context(ctx)(), {"origin": "chat", "platform": ""})


class PapertrailRouteTests(unittest.TestCase):
    PATH = "/api/plugins/nollie-workflow/papertrail"

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("workflow_api_papertrail_test", ROOT / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)
        app = fastapi.FastAPI()
        app.include_router(cls.api.router, prefix="/api/plugins/nollie-workflow")
        cls.client = TestClient(app)

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.active = "default"
        self.bots = {"career": self.home / "profiles" / "career", "mason": self.home / "profiles" / "mason"}
        for path in (self.home, *self.bots.values()):
            (path / "nollie-workflow" / "papertrail").mkdir(parents=True, exist_ok=True)
        (self.bots["mason"] / "nollie-workflow" / "papertrail").rmdir()
        recorder = papertrail.Recorder(self.bots["career"])
        recorder.post_api_request(turn_id="t-1", provider="anthropic", base_url="https://api.anthropic.com",
                                  usage=usage(10, 2))
        self.assertTrue(recorder.flush())

        def profile_dir(name):
            if name == "default":
                return self.home
            if name not in self.bots:
                self.fail(f"looked up {name}")
            return self.bots[name]

        profiles = SimpleNamespace(get_active_profile_name=lambda: self.active, get_profile_dir=profile_dir,
                                   profile_exists=lambda name: name in self.bots)
        modules = patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles,
                                             "hermes_cli.providers": SimpleNamespace(get_provider=None)})
        modules.start()
        self.addCleanup(modules.stop)

    def get(self, **params):
        response = self.client.get(self.PATH, params=params)
        self.assertEqual(response.headers.get("cache-control"), "no-store", (params, response.status_code))
        return response

    def test_schedule_names_are_read_now_and_a_private_name_is_left_out(self):
        recorder = papertrail.Recorder(self.bots["career"], context=lambda: {"origin": "schedule", "job": "j1"})
        recorder.post_api_request(turn_id="t-2", provider="anthropic", base_url="https://api.anthropic.com",
                                  usage=usage(10, 2))
        recorder = papertrail.Recorder(self.bots["career"], context=lambda: {"origin": "schedule", "job": "j2"})
        recorder.post_api_request(turn_id="t-3", provider="anthropic", base_url="https://api.anthropic.com",
                                  usage=usage(10, 2))
        self.assertTrue(recorder.flush())

        class Jobs:
            def __init__(self, home):
                pass

            def jobs(self, profile):
                return [{"id": "j1", "name": "Morning prices"}, {"id": "j2", "name": "Moss diary"}]
        with patch.object(self.api._adapter, "ProfileJobs", Jobs):
            body = self.get(bot="career").json()
        whys = {e["id"]: e.get("why") for e in body["entries"]}
        self.assertEqual(whys["t-2"]["task"], "Morning prices")
        self.assertIsNone(whys["t-3"]["task"])
        self.assertIsNone(whys["t-1"])  # Kept before reasons were.

    def test_a_bot_with_papertrail_gets_its_record(self):
        response = self.get(bot="career", days="3")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual((body["bot"], body["days"], body["left"]["window"]), ("career", 3, 1))
        self.assertEqual(body["entries"][0]["provider"], "anthropic")
        self.assertEqual(set(body), {"bot", "days", "now", "today_starts_at", "tomorrow_starts_at", "since", "recording_since",
                                     "stayed", "left", "entries", "more", "mac_sessions"})
        default = self.get()
        self.assertEqual((default.status_code, default.json()["bot"], default.json()["days"]), (200, "default", 7))

    def test_private_bots_are_refused_before_their_home_is_looked_up(self):
        for bot in ("moss", "private"):
            response = self.get(bot=bot)
            self.assertEqual((response.status_code, response.json()["detail"]),
                             (403, "Papertrail is not kept for private bots."))
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.get(bot="career").status_code, 403)
        self.assertEqual(self.get(bot="moss").status_code, 403, "the carried-over names always count")

    def test_the_mac_app_records_a_note_it_sent_through_icloud(self):
        path = self.PATH + "/icloud"
        response = self.client.post(path, json={"bot": "career", "kind": "reply"})
        self.assertEqual((response.status_code, response.json()), (200, {"recorded": True}))
        self.assertEqual(response.headers.get("cache-control"), "no-store")
        entries = self.get(bot="career").json()["entries"]
        self.assertIn("icloud", {e["route"] for e in entries})
        for body in ({"bot": "career", "kind": "shell"}, {"bot": "../x", "kind": "reply"}):
            self.assertEqual(self.client.post(path, json=body).status_code, 422)
        self.assertEqual(self.client.post(path, json={"bot": "moss", "kind": "reply"}).status_code, 403)
        # A bot with Papertrail off: nothing is made for it.
        response = self.client.post(path, json={"bot": "mason", "kind": "card"})
        self.assertEqual(response.json(), {"recorded": False})
        self.assertFalse((self.bots["mason"] / "nollie-workflow" / "papertrail").exists())

    def test_the_mac_app_records_each_time_a_bot_used_this_mac(self):
        path = self.PATH + "/mac-session"
        response = self.client.post(path, json={"bot": "career", "apps": ["Notes", "Safari"], "actions": 4, "looks": 5})
        self.assertEqual((response.status_code, response.json()), (200, {"recorded": True}))
        body = self.get(bot="career").json()
        self.assertEqual([(s["apps"], s["actions"], s["looks"], s["screenshots_left"]) for s in body["mac_sessions"]],
                         [(["Notes", "Safari"], 4, 5, 0)])
        self.assertNotIn("mac", {e["route"] for e in body["entries"]}, "it stayed on the Mac, so nothing is listed as left")
        for bad in ({"bot": "career", "apps": [], "actions": 1}, {"bot": "../x", "apps": ["Notes"], "actions": 1},
                    {"bot": "career", "apps": ["Notes"], "actions": "many"}):
            self.assertEqual(self.client.post(path, json=bad).status_code, 422, bad)
        self.assertEqual(self.client.post(path, json={"bot": "moss", "apps": ["Notes"], "actions": 1}).status_code, 403)
        response = self.client.post(path, json={"bot": "mason", "apps": ["Notes"], "actions": 1})
        self.assertEqual(response.json(), {"recorded": False})

    def test_unknown_bots_and_bots_without_papertrail_get_404(self):
        response = self.get(bot="scout")
        self.assertEqual((response.status_code, response.json()["detail"]), (404, "No such bot."))
        response = self.get(bot="mason")
        self.assertEqual((response.status_code, response.json()["detail"]), (404, "Papertrail is not on for this bot."))

    def test_malformed_names_and_days_get_422(self):
        for params in ({"bot": "../career"}, {"bot": "Career"}, {"bot": "two words"}, {"bot": ""},
                       {"days": "0"}, {"days": "36"}, {"days": "x"}, {"days": "-1"}, {"days": "7.5"}):
            self.assertEqual(self.get(**params).status_code, 422, params)

    def test_other_profiles_are_refused_and_a_damaged_private_list_is_unavailable(self):
        self.active = "career"
        self.assertEqual(self.get(bot="career").status_code, 403)
        self.active = "default"
        (self.home / "nollie-private-bots.json").write_text("{")
        self.assertEqual(self.get(bot="career").status_code, 503)


class RegisterTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.default = Path(temp.name) / ".hermes"
        self.default.mkdir()
        (self.default / "nollie-workflow").mkdir()
        (self.default / "nollie-workflow" / "state.json").write_text("{}")
        self.callbacks = {}

    def register(self, profile):
        bot_home = self.default if profile == "default" else self.default / "profiles" / profile
        bot_home.mkdir(parents=True, exist_ok=True)
        ctx = SimpleNamespace(profile_name=profile, hooks=[])
        ctx.register_hook = lambda name, callback: (ctx.hooks.append(name), self.callbacks.update({name: callback}))
        modules = {"hermes_cli": SimpleNamespace(),
                   "hermes_cli.profiles": SimpleNamespace(get_profile_dir=lambda name: self.default),
                   "hermes_constants": SimpleNamespace(get_hermes_home=lambda: bot_home)}
        # The Night shift recorder and Ask first register beside Papertrail; test_night_plumbing covers them.
        with patch.dict("sys.modules", modules), patch.object(package, "_register_night_shift"), \
                patch.object(package, "_register_ask_first"), patch.object(package, "_register_mac_screen"), \
                patch.object(service, "start") as start, patch.object(followup_tools, "register") as followups:
            package.register(ctx)
        return ctx.hooks, start.called, followups.called, (bot_home / "nollie-workflow" / "papertrail").is_dir()

    def test_every_bot_that_is_not_private_records_and_only_default_runs_the_board(self):
        # The two log privacy hooks come first: they let Hermes's logs leave a quoted message out.
        hooks = ["pre_llm_call", "post_llm_call", *papertrail.HOOKS]
        self.assertEqual(self.register("career"), (hooks, False, False, True))
        self.assertEqual(self.register("default"), (hooks, True, True, True))

    def test_private_bots_never_record(self):
        for profile in ("moss", "private", "moss-2"):
            self.assertEqual(self.register(profile), ([], False, False, False), profile)
        private_bots.save(self.default, ["scout"])
        self.assertEqual(self.register("scout"), ([], False, False, False))
        self.assertEqual(self.register("moss"), ([], False, False, False))
        (self.default / "nollie-private-bots.json").write_text("{")
        self.assertEqual(self.register("career")[0], [], "a damaged list keeps every bot unrecorded")

    def fire(self):
        self.callbacks["post_api_request"](turn_id="t-1", provider="anthropic", base_url="https://api.anthropic.com",
                                           usage=usage(10, 2))
        self.callbacks["post_tool_call"](tool_name="web_search", status="ok", turn_id="t-1")
        self.assertTrue(self.callbacks["post_api_request"].__self__.flush())

    def test_a_bot_marked_private_later_stops_recording_at_once(self):
        self.register("career")
        root = self.default / "profiles" / "career" / "nollie-workflow" / "papertrail"
        self.fire()
        self.assertEqual(len(lines(root)), 2)
        private_bots.save(self.default, ["career"])
        self.fire()
        self.assertEqual(len(lines(root)), 2, "nothing more is written once the bot is private")
        private_bots.save(self.default, [])
        self.fire()
        self.assertEqual(len(lines(root)), 4)
        (self.default / "nollie-private-bots.json").write_text("{")
        self.fire()
        self.assertEqual(len(lines(root)), 4, "a damaged list stops recording")
        self.assertFalse((root / "last_error").exists())


class InstallTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.hermes = self.home / ".hermes"
        for name in ("career", "nowhere", "moss", "scout"):
            (self.hermes / "profiles" / name).mkdir(parents=True)
        (self.hermes / "hermes-agent" / "hermes_cli").mkdir(parents=True)

    def tree(self):
        return sorted(str(p.relative_to(self.home)) for p in self.home.rglob("*"))

    def main(self, *argv):
        with patch.object(Path, "home", return_value=self.home), patch("sys.argv", ["install.py", *argv]), \
                patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                patch.object(installer.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run, \
                patch("builtins.print"):
            installer.main()
        return [call.args[0] for call in run.call_args_list]

    def test_plan_mode_names_the_bots_and_writes_nothing(self):
        before = self.tree()
        self.assertEqual(self.main("--papertrail-bots", "career,nowhere", "--enable"), [])
        self.assertEqual(self.tree(), before)

    def test_private_unknown_and_malformed_names_are_refused_before_anything_is_written(self):
        private_bots.save(self.hermes, ["scout"])
        before = self.tree()
        for names in ("career,moss", "private", "scout", "career,ghost", "../career", "two words"):
            with self.assertRaises(SystemExit, msg=names):
                self.main("--apply", "--enable", "--papertrail-bots", names)
            self.assertEqual(self.tree(), before, names)

    def test_apply_copies_into_each_bot_and_enables_it_there(self):
        config = self.hermes / "profiles" / "career" / "config.yaml"
        config.write_text("model: {}\n")
        commands = self.main("--apply", "--enable", "--papertrail-bots", "career, nowhere,default,career")
        self.assertEqual([command[2] for command in commands], ["default", "career", "nowhere"])
        for name in ("career", "nowhere"):
            target = self.hermes / "profiles" / name / "plugins" / "nollie-workflow"
            self.assertTrue((target / "papertrail.py").is_file())
            self.assertFalse((target / "tests").exists())
            self.assertFalse((self.hermes / "profiles" / name / "nollie-workflow" / "state.json").exists())
        self.assertFalse((self.hermes / "profiles" / "moss" / "plugins").exists())
        self.assertEqual(next(config.parent.glob("config.yaml.bak-nollie-workflow-*")).read_text(), "model: {}\n")
        self.main("--apply", "--papertrail-bots", "career")
        self.assertEqual(len(list((config.parent / "plugin-backups").iterdir())), 1)


HERMES_SCRIPT = r'''
import json, os, shutil, sys, time
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, os.environ["HERMES_SRC"])
home = Path(os.environ["HERMES_HOME"])
profile = os.environ["BOT"]
bot_home = home if profile == "default" else home / "profiles" / profile
bot_home.mkdir(parents=True, exist_ok=True)
shutil.copytree(os.environ["ADDON"], bot_home / "plugins" / "nollie-workflow",
                ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc"))
(bot_home / "config.yaml").write_text("plugins:\n  enabled: [nollie-workflow]\nweb:\n  search_backend: exa\n")
if profile != "default":
    os.environ["HERMES_HOME"] = str(bot_home)
from hermes_cli import plugins
plugins.discover_plugins()
manager = plugins.get_plugin_manager()
loaded = {key: (bool(p.enabled), p.error and type(p.error).__name__) for key, p in manager._plugins.items()}
hooks = sorted(name for name in ("post_api_request", "api_request_error", "post_auxiliary_call", "post_tool_call")
               if plugins.has_hook(name))

# The real call sites, so the keyword arguments are Hermes's own.
from agent.api_request_hooks import ApiRequestHooksMixin
from agent.auxiliary_hooks import _AuxCallHooks
from agent.turn_response_intake import _fire_post_api_request_hook
import model_tools

class Agent(ApiRequestHooksMixin):
    session_id, platform, model, api_mode = "s-1", "api_server", "claude-sonnet-5-5", "chat_completions"
    provider, base_url = "claude-subscription-direct", "process://claude-subscription-direct"
    _last_api_first_chunk_at = None
    context_compressor = None
    def _api_response_payload_for_hook(self, response, assistant_message, finish_reason=None):
        return {}

reply = SimpleNamespace(content="secret-reply", tool_calls=[])
response = SimpleNamespace(model="claude-sonnet-5-5", usage=SimpleNamespace(prompt_tokens=1200, completion_tokens=340))
_fire_post_api_request_hook(Agent(), response, reply, "stop", api_messages=[{"role": "user", "content": "secret-prompt"}],
                            api_call_count=1, api_duration=0.5, api_start_time=time.time() - 1, api_request_id="r-1",
                            effective_task_id="", turn_id="t-1")
agent = Agent()
agent.provider, agent.base_url = "openrouter", "https://u:secretpass@openrouter.ai/api/v1?token=secret-token"
agent._invoke_api_request_error_hook(task_id="", turn_id="t-1", api_request_id="r-2", api_call_count=2,
                                     api_start_time=time.time() - 1, api_kwargs={"messages": ["secret-prompt"]},
                                     error_type="Timeout", error_message="secret-error")
aux = _AuxCallHooks(aux_task="title_generation", metadata={}, client=SimpleNamespace(base_url="http://127.0.0.1:18434/v1"),
                    kwargs={"messages": [{"role": "user", "content": "secret-prompt"}]}, provider="llamacpp",
                    model="qwen3", api_mode="chat_completions", streaming=False)
aux.post(SimpleNamespace(model="qwen3", choices=[{"message": {"content": "secret-reply"}, "finish_reason": "stop"}],
                         usage=SimpleNamespace(prompt_tokens=50, completion_tokens=8)))
model_tools._emit_post_tool_call_hook(function_name="web_search", function_args={"query": "secret-query"},
                                      result='{"success": true}', session_id="s-1", turn_id="t-1")
model_tools._emit_post_tool_call_hook(function_name="web_search", function_args={"query": "secret-query"},
                                      result="{}", session_id="s-1", turn_id="t-1", status="blocked")
deadline = time.time() + 20
root = bot_home / "nollie-workflow" / "papertrail"
while time.time() < deadline and len([l for f in root.glob("*.jsonl") for l in f.read_text().splitlines()]) < 4:
    time.sleep(0.05)
text = "".join(f.read_text() for f in root.glob("*.jsonl")) if root.is_dir() else ""
answer = None
if root.is_dir():
    spec_path = bot_home / "plugins" / "nollie-workflow" / "papertrail.py"
    import importlib.util
    spec = importlib.util.spec_from_file_location("papertrail_reader_check", spec_path)
    reader = importlib.util.module_from_spec(spec); spec.loader.exec_module(reader)
    answer = reader.read(bot_home, profile, 7)
print(json.dumps({"loaded": loaded, "hooks": hooks, "lines": [json.loads(l) for l in text.splitlines()],
                  "text": text, "answer": answer, "folder": root.is_dir()}))
'''


@unittest.skipUnless(HERMES_PYTHON and (HERMES_SOURCE / "hermes_cli" / "plugins.py").is_file(),
                     "set NOLLIE_HERMES_PYTHON to Hermes's own Python to run these")
class HermesIntegrationTests(unittest.TestCase):
    """Hermes's plugin manager loads the add-on from a throwaway home and its own call sites fire the hooks."""

    def run_bot(self, bot):
        with TemporaryDirectory() as home:
            env = {"PATH": "/usr/bin:/bin", "HOME": home, "HERMES_HOME": str(Path(home) / ".hermes"),
                   "HERMES_SRC": str(HERMES_SOURCE), "ADDON": str(ROOT), "BOT": bot, "PYTHONDONTWRITEBYTECODE": "1",
                   # A throwaway home must not build its own Hermes environment; it borrows this one.
                   "HERMES_DISABLE_LAZY_INSTALLS": "1"}
            Path(env["HERMES_HOME"]).mkdir()
            done = subprocess.run([HERMES_PYTHON, "-B", "-c", HERMES_SCRIPT], capture_output=True, text=True,
                                  env=env, timeout=240)
        if done.returncode:
            raise AssertionError(done.stderr[-3000:])
        return json.loads(done.stdout.strip().splitlines()[-1])

    def test_real_hooks_reach_the_recorder_with_hermes_keyword_arguments(self):
        report = self.run_bot("career")
        self.assertEqual(report["loaded"].get("nollie-workflow"), [True, None], report["loaded"])
        self.assertEqual(report["hooks"], sorted(papertrail.HOOKS))
        for secret in SECRETS:
            self.assertNotIn(secret, report["text"])
        model, error, helper, search = report["lines"]
        self.assertEqual((model["source"], model["route"], model["provider"], model["turn"], model["in"], model["out"]),
                         ("model", "online", SUBSCRIPTION, "t-1", 1200, 340))
        self.assertEqual((error["route"], error["host"], error["provider"]), ("online", "https://openrouter.ai", "openrouter"))
        self.assertEqual((helper["source"], helper["task"], helper["route"], helper["in"], helper["out"]),
                         ("helper", "title_generation", "mac", 50, 8))
        self.assertEqual((search["tool"], search["provider"], search["searches"]), ("web_search", "exa", 1))
        entry = report["answer"]["entries"][0]
        self.assertEqual((entry["id"], entry["calls"], entry["services"], entry["provider"]),
                         ("t-1", 3, ["exa"], SUBSCRIPTION))

    def test_a_private_bot_loaded_by_hermes_records_nothing(self):
        report = self.run_bot("moss")
        self.assertEqual(report["loaded"].get("nollie-workflow"), [True, None], report["loaded"])
        self.assertEqual(report["hooks"], [])
        self.assertFalse(report["folder"])


if __name__ == "__main__":
    unittest.main()
