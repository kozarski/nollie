"""Isolated process fixtures for the bundled runtime entry point. No Hermes imports."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENTRY = Path(__file__).resolve().parents[2] / "Services/Runtime" / "runtime_entry.py"


class RuntimeEntryTests(unittest.TestCase):
    def launch(self, role, descriptor=True, profiles_fail=False):
        directory = tempfile.TemporaryDirectory(prefix="nollie-runtime-entry-")
        self.addCleanup(directory.cleanup)
        package = Path(directory.name) / "hermes_cli"
        package.mkdir()
        (package / "__init__.py").write_text("")
        (package / "main.py").write_text(
            "import json,os,signal,sys,time\n"
            "print(json.dumps({'argv':sys.argv[1:],'owner_inherited': 'NOLLIE_OWNER_FD' in os.environ, 'api_prepared':os.environ.get('NOLLIE_FIXTURE_PREPARED') == 'yes', 'profiles_prepared':os.environ.get('NOLLIE_FIXTURE_PROFILES') == 'yes'}),flush=True)\n"
            "signal.signal(signal.SIGTERM, lambda *_:sys.exit(0))\n"
            "while True: time.sleep(0.05)\n"
        )
        reader, writer = os.pipe()
        environment = {"PATH": "/usr/bin:/bin", "NOLLIE_OWNER_FD": str(reader if descriptor else 0)}
        # The fixture has no Hermes source. Catalog behavior has separate pinned-source tests.
        prepare_profiles = "lambda _: sys.exit(78)" if profiles_fail else "lambda _: os.environ.__setitem__('NOLLIE_FIXTURE_PROFILES', 'yes')"
        bootstrap = f"import os,runpy,sys; runpy.run_path({str(ENTRY)!r})['main'](prepare_api=lambda _: os.environ.__setitem__('NOLLIE_FIXTURE_PREPARED', 'yes'), prepare_profiles={prepare_profiles})"
        child = subprocess.Popen([sys.executable, "-I", "-B", "-c", bootstrap, "--source", directory.name, "--role", role],
                                 env=environment, pass_fds=(reader,), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        os.close(reader)
        def cleanup():
            try: os.close(writer)
            except OSError: pass
            if child.poll() is None: child.kill()
            child.wait(timeout=3)
            child.stdout.close()
        self.addCleanup(cleanup)
        return child, writer

    def test_api_has_only_isolated_loopback_serve_arguments(self):
        child, _ = self.launch("api")
        result = json.loads(child.stdout.readline())
        self.assertEqual(result["argv"], ["--profile", "default", "serve", "--host", "127.0.0.1", "--port", "0", "--isolated"])
        self.assertFalse(result["owner_inherited"])
        self.assertTrue(result["api_prepared"])
        self.assertTrue(result["profiles_prepared"])

    def test_gateway_is_foreground_externally_supervised(self):
        child, _ = self.launch("gateway")
        result = json.loads(child.stdout.readline())
        self.assertEqual(result["argv"], ["--profile", "default", "gateway", "run", "--external-supervisor"])
        self.assertFalse(result["api_prepared"])
        self.assertTrue(result["profiles_prepared"])

    def test_owner_disappearance_stops_only_the_owned_child(self):
        child, writer = self.launch("gateway")
        json.loads(child.stdout.readline())
        os.close(writer)
        child.wait(timeout=12)
        self.assertEqual(child.returncode, 0)

    def test_no_owner_pipe_refuses_to_import_or_start_runtime(self):
        child, _ = self.launch("api", descriptor=False)
        child.wait(timeout=3)
        self.assertEqual(child.returncode, 78)
        self.assertEqual(child.stdout.read(), "")

    def test_ask_first_setup_failure_prevents_either_role_from_starting(self):
        for role in ("api", "gateway"):
            with self.subTest(role=role):
                child, _ = self.launch(role, profiles_fail=True)
                child.wait(timeout=3)
                self.assertEqual(child.returncode, 78)
                self.assertEqual(child.stdout.read(), "")


SECRET = "ab" * 32
DOOR = f"http://unplaced.program:{SECRET}@127.0.0.1:41234"

# Labels the door, inside a fresh interpreter, then reports what a request and each kind of child would carry.
LABEL_SCRIPT = r"""
import json, os, runpy, subprocess, sys, types, urllib.request
entry = runpy.run_path(sys.argv[1])
bot = {"name": "career"}
labelled = entry["_label_door"](bot=lambda: bot["name"])
said = {"labelled": labelled, "request": urllib.request.getproxies().get("https")}
child = [sys.executable, "-I", "-c", "import json,os;print(json.dumps({k: os.environ.get(k) for k in "
         "('HTTPS_PROXY','http_proxy','ALL_PROXY','NO_PROXY','NODE_USE_ENV_PROXY','KEEP')}))"]

def spawn(module, env):
    code = compile("def run(child, env):\n    import subprocess\n    return subprocess.run(child, env=env, capture_output=True, text=True).stdout", module, "exec")
    namespace = {"__name__": module}
    exec(code, namespace)
    return json.loads(namespace["run"](child, env))

said["terminal"] = spawn("tools.terminal_tool", None)
said["mcp"] = spawn("tools.mcp_tool_transport", {"PATH": "/usr/bin:/bin", "KEEP": "yes"})
bot["name"] = "moss"
said["code"] = spawn("tools.code_execution_tool", None)
said["own"] = spawn("somewhere.else", {"PATH": "/usr/bin:/bin", "HTTPS_PROXY": "http://their.proxy:3128"})
print(json.dumps(said))
"""


class DoorLabelTests(unittest.TestCase):
    def run_labels(self, extra=None):
        environment = {"PATH": "/usr/bin:/bin", "HERMES_HOME": "/tmp/nollie-fixture-home",
                       **{name: DOOR for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy",
                                                  "https_proxy", "all_proxy")},
                       "NO_PROXY": "localhost,127.0.0.1,::1", **(extra or {})}
        out = subprocess.run([sys.executable, "-I", "-B", "-c", LABEL_SCRIPT, str(ENTRY)], env=environment,
                             capture_output=True, text=True, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    def test_requests_and_children_carry_the_bot_and_kind(self):
        said = self.run_labels()
        self.assertTrue(said["labelled"])
        door = lambda label: f"http://{label}:{SECRET}@127.0.0.1:41234"
        self.assertEqual(said["request"], door("career.hermes"))
        self.assertEqual(said["terminal"]["HTTPS_PROXY"], door("career.terminal"))
        self.assertEqual(said["terminal"]["http_proxy"], door("career.terminal"))
        # Hermes gives a server only a few variables; the door's are put back, the rest stays as given.
        self.assertEqual(said["mcp"]["ALL_PROXY"], door("career.mcp"))
        self.assertEqual(said["mcp"]["NO_PROXY"], "localhost,127.0.0.1,::1")
        self.assertEqual(said["mcp"]["NODE_USE_ENV_PROXY"], "1")
        self.assertEqual(said["mcp"]["KEEP"], "yes")
        # A private bot's label is still its own: the door then writes nothing for it.
        self.assertEqual(said["code"]["HTTPS_PROXY"], door("moss.code"))
        # A proxy a program chose for itself is left alone.
        self.assertEqual(said["own"]["HTTPS_PROXY"], "http://their.proxy:3128")
        self.assertEqual(said["own"]["ALL_PROXY"], door("moss.program"))

    def test_nothing_is_labelled_without_the_door(self):
        said = self.run_labels({"HTTPS_PROXY": "http://elsewhere:8080"})
        self.assertFalse(said["labelled"])
        self.assertEqual(said["terminal"]["HTTPS_PROXY"], "http://elsewhere:8080")

    def test_homes_name_their_bots(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("nollie_runtime_entry_labels", ENTRY)
        entry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entry)
        home = Path("/tmp/setup/home")
        self.assertEqual(entry._bot_of(home, home), "default")
        self.assertEqual(entry._bot_of(home / "profiles" / "scout", home), "scout")
        self.assertEqual(entry._bot_of(home / "profiles" / ".scout.staging-1", home), "unplaced")
        self.assertEqual(entry._bot_of(Path("/elsewhere/profiles/scout"), home), "unplaced")
        self.assertEqual(entry._bot_of(home / "profiles" / "unplaced", home), "unplaced")


if __name__ == "__main__":
    unittest.main()
