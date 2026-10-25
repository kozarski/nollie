"""Checks against Hermes's own code, imported read-only in a temporary home with no network.

Runs only when NOLLIE_HERMES_PYTHON names Hermes's Python (the venv the gateway uses). The
source tree is never written: bytecode is off and HERMES_HOME is a temporary folder.
"""
import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest

HERMES_SOURCE = Path(os.environ.get("NOLLIE_HERMES_SOURCE", Path.home() / ".hermes" / "hermes-agent"))
HERMES_PYTHON = os.environ.get("NOLLIE_HERMES_PYTHON", "")
TESTS = Path(__file__).resolve().parent

PRELUDE = r'''
import json, os, sys
sys.path.insert(0, os.environ["HERMES_SRC"])
sys.path.insert(0, os.environ["TESTS_DIR"])
import support
mods = support.load()
'''


def run(script, **extra):
    with TemporaryDirectory() as home, TemporaryDirectory() as state:
        env = {"PATH": "/usr/bin:/bin", "HOME": home, "HERMES_HOME": home, "HERMES_SRC": str(HERMES_SOURCE),
               "TESTS_DIR": str(TESTS), "STATE": state, "NOLLIE_READER_HOME": state,
               "PYTHONDONTWRITEBYTECODE": "1", **extra}
        done = subprocess.run([HERMES_PYTHON, "-B", "-c", PRELUDE + script], capture_output=True, text=True,
                              env=env, timeout=180)
    if done.returncode:
        raise AssertionError(done.stderr[-3000:])
    return json.loads(done.stdout.strip().splitlines()[-1])


@unittest.skipUnless(HERMES_PYTHON and (HERMES_SOURCE / "plugins" / "web" / "keyless_mcp.py").is_file(),
                     "set NOLLIE_HERMES_PYTHON to Hermes's own Python to run these")
class HermesIntegrationTests(unittest.TestCase):
    def test_limits_reach_the_real_keyless_ring(self):
        report = run(r'''
from plugins.web import keyless_mcp as km
calls = []
def fake_mcp(url, tool, arguments, timeout=30):
    calls.append(url)
    if "parallel" in url:
        return json.dumps({"results": [{"url": "https://b.example/", "title": "B", "excerpts": ["y"]}]})
    return "Title: A\nURL: https://a.example/\nHighlights:\nx"
km.mcp_call = fake_mcp
km._web_config_selects = lambda name: name == "exa"
km.provider_tier = lambda name: "auto"
limits = mods["limits"].ServiceLimits(os.environ["STATE"], services={"exa": {"interval": 0, "daily": 1}})
mods["search_limits"].install(km, os.environ["STATE"], limits=limits)
first = km.search_with_failover("exa", "one", 1)
second = km.search_with_failover("exa", "two", 1)
print(json.dumps({"first": first.get("success"), "second_by": (second.get("data") or {}).get("served_by"),
                  "calls": calls}))
''')
        self.assertTrue(report["first"])
        self.assertEqual(report["second_by"], "parallel")
        self.assertEqual(report["calls"], ["https://mcp.exa.ai/mcp", "https://search.parallel.ai/mcp"])

    def test_a_site_that_wants_a_person_is_not_rescued_elsewhere(self):
        report = run(r'''
import asyncio, importlib
glue = importlib.import_module("nollie_reader_under_test.hermes_glue")
netsafe, reader_mod, extract = mods["netsafe"], mods["reader"], mods["extract"]
site = support.Site({"/robots.txt": (200, {}, "User-agent: *\nAllow: /\n"), "/locked": (403, {}, "no")})
resolver, allowed = support.test_network(netsafe, {"locked.example.com": "127.0.0.1"})
reader = reader_mod.Reader(os.environ["STATE"], resolver=resolver, allowed=allowed, host_interval=0,
                           helper=extract.Helper(None))
provider = glue.make_provider(lambda: reader)
from plugins.web import keyless_mcp as km
rescued = []
km.extract_with_failover = lambda name, urls: rescued.append(urls) or [{"url": u, "content": "elsewhere"} for u in urls]
from tools import web_tools_extract as wte
url = f"http://locked.example.com:{site.port}/locked"
results = asyncio.run(wte._dispatch_extract(provider, [url], "markdown"))
refused_rescues = list(rescued)
# Control: an ordinary failure (404) IS handed to the ring unless web.keyless_rescue is off.
asyncio.run(wte._dispatch_extract(provider, [f"http://locked.example.com:{site.port}/missing"], "markdown"))
site.close()
print(json.dumps({"rescued": refused_rescues, "control": len(rescued) - len(refused_rescues),
                  "error": results[0].get("error"), "blocked": results[0].get("blocked_by_policy"),
                  "capable": [provider.supports_search(), provider.supports_extract(), provider.is_available()]}))
''')
        self.assertEqual(report["rescued"], [])
        self.assertEqual(report["control"], 1)
        self.assertTrue(report["error"].startswith("This site wants a person"))
        self.assertTrue(report["blocked"])
        self.assertEqual(report["capable"], [False, True, True])

    def test_plugin_registers_with_a_plugin_context(self):
        report = run(r'''
import importlib
pkg = importlib.import_module("nollie_reader_under_test")
seen = {}
class Ctx:
    profile_name = "career"
    def register_web_search_provider(self, provider): seen["provider"] = provider.name
    def register_tool(self, name, toolset, schema, handler, **kw): seen["tool"] = [name, toolset]; seen["handler"] = handler
    def register_skill(self, name, path, description=""): seen["skill"] = name
    def register_hook(self, name, callback): seen["hook"] = name
    def on_unload(self, callback): seen["unload"] = True
pkg.register(Ctx())
private = {}
class PrivateCtx(Ctx):
    profile_name = "private"
    def register_tool(self, *a, **k): private["tool"] = True
pkg.register(PrivateCtx())
from plugins.web import keyless_mcp as km
answer = json.loads(seen.pop("handler")({"source": "nowhere"}))
print(json.dumps({**seen, "private": private, "limited": getattr(km.exa_search_keyless, "_nollie_limited", False),
                  "answer": answer}))
''')
        self.assertEqual(report["provider"], "nollie-reader")
        self.assertEqual(report["tool"], ["reference_lookup", "web"])
        self.assertEqual(report["skill"], "reference-sources")
        self.assertEqual(report["hook"], "pre_tool_call")
        self.assertTrue(report["unload"])
        self.assertTrue(report["limited"])
        self.assertEqual(report["private"], {})
        self.assertFalse(report["answer"]["ok"])


if __name__ == "__main__":
    unittest.main()
