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


if __name__ == "__main__":
    unittest.main()
