"""Nollie Runtime's exit relay as the computer add-on sees it: the state file it reads, when the
exit node card shows, and how a helper's computer is pointed at the relay once."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
import textwrap
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("own_computer_relay", HERE.parent / "dashboard/own_computer.py")
own = importlib.util.module_from_spec(spec)
spec.loader.exec_module(own)
fakes_spec = importlib.util.spec_from_file_location("own_computer_fakes", HERE / "test_own_computer.py")
fakes = importlib.util.module_from_spec(fakes_spec)
fakes_spec.loader.exec_module(fakes)


def write(path, document):
    path.write_text(document if isinstance(document, str) else json.dumps(document))
    return path


class RelayStateTests(unittest.TestCase):
    def test_reads_exactly_what_the_runtime_writes(self):
        with TemporaryDirectory() as folder:
            path = Path(folder) / "exit-relay.json"
            self.assertIsNone(own.read_relay_state(path))
            write(path, {"version": 1, "state": "on", "port": 47610})
            self.assertEqual(own.read_relay_state(path), {"state": "on", "port": 47610})
            for bad in ({"version": 2, "state": "on", "port": 47610}, {"version": 1, "state": "maybe", "port": 47610},
                        {"version": 1, "state": "on", "port": "47610"}, {"version": 1, "state": "on", "port": True},
                        {"version": 1, "state": "on", "port": 80}, {"version": 1, "state": "on"}, [1], "not json",
                        {"version": 1, "state": "on", "port": 47610, "pad": "x" * 5000}):
                write(path, bad)
                self.assertIsNone(own.read_relay_state(path), bad)
            real = write(Path(folder) / "real.json", {"version": 1, "state": "on", "port": 47610})
            path.unlink()
            path.symlink_to(real)
            self.assertIsNone(own.read_relay_state(path))

    def test_the_runtime_names_the_file_else_the_persons_nollie_folder(self):
        named = "/Users/me/Library/Application Support/Nollie/RuntimeService/exit-relay.json"
        self.assertEqual(own.relay_state_path({"NOLLIE_EXIT_RELAY": named}, home="/Users/me"), Path(named))
        default = Path("/Users/me") / own.RELAY_STATE
        for odd in ("relative/exit-relay.json", "/tmp/other.json", "/a/../exit-relay.json", ""):
            self.assertEqual(own.relay_state_path({"NOLLIE_EXIT_RELAY": odd}, home="/Users/me"), default, odd)
        self.assertEqual(own.relay_state_path({}, home="/Users/me"), default)


class CardTests(unittest.TestCase):
    def computers(self, exit_node, relay):
        return own.OwnComputers(home="/nowhere", run=lambda *a, **k: (None, ""), exit_node=lambda: exit_node,
                                relay=lambda: relay)

    def test_the_card_shows_only_when_the_relay_does_not_carry_the_traffic(self):
        on = {"state": "on", "port": 47610}
        self.assertIsNone(self.computers(False, None).internet({"relay": 47610}))
        self.assertIsNone(self.computers(False, {"state": "failed", "port": 47610}).internet({}))
        self.assertEqual(self.computers(True, on).internet({"relay": 47610}), "relay")
        self.assertEqual(self.computers(True, {"state": "idle", "port": 47610}).internet({"relay": 47610}), "relay")
        for relay in ({"state": "failed", "port": 47610}, {"state": "off", "port": 47610}, None):
            self.assertEqual(self.computers(True, relay).internet({"relay": 47610}), "exit_node", relay)
        # A computer never pointed at the relay, or at another port, still has no internet.
        for entry in ({}, {"relay": None}, {"relay": 47611}, {"relay": "47610"}, {"relay": True}):
            self.assertEqual(self.computers(True, on).internet(entry), "exit_node", entry)


class PointingTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.mac = fakes.FakeMac(self.directory.name)
        self.calls = []
        self.works = True

    def tearDown(self):
        self.directory.cleanup()

    def space_bash(self, cua, sock, env, space, command):
        self.calls.append((cua, Path(sock), env, space, command))
        return self.works

    def make(self, relay=None):
        return own.OwnComputers(home=self.mac.home, run=self.mac.run, hermes="/fake/hermes", cua="/fake/cua",
                                homes=self.mac.profile_home, spawn=lambda work: work(), yaml_load=json.loads,
                                exit_node=lambda: True, relay=lambda: relay, space_bash=self.space_bash)

    def test_turning_on_points_the_new_computer_at_the_relay_once(self):
        computers = self.make({"state": "on", "port": 47610})
        computers.change("work", "on", "request-0001")
        self.assertEqual(len(self.calls), 1)
        cua, sock, env, space, command = self.calls[0]
        self.assertEqual((cua, sock, env, space), ("/fake/cua", self.mac.home / ".cua/cua.sock",
                                                   {"HOME": str(self.mac.home)}, "local:nollie-work"))
        self.assertEqual(command, own.relay_script(47610))
        self.assertEqual(computers.record("work")["relay"], 47610)
        status = computers.status("work")
        self.assertEqual((status["state"], status["internet"]), ("ready", "relay"))

    def test_without_a_relay_file_it_still_points_at_the_usual_port(self):
        computers = self.make(None)
        computers.change("work", "on", "request-0002")
        self.assertEqual(self.calls[0][4], own.relay_script(own.RELAY_PORT))
        self.assertEqual(computers.status("work")["internet"], "exit_node")

    def test_a_computer_that_cannot_be_pointed_keeps_working_and_the_card_stays(self):
        self.works = False
        computers = self.make({"state": "on", "port": 47610})
        computers.change("work", "on", "request-0003")
        status = computers.status("work")
        self.assertEqual((status["on"], status["state"], status["internet"]), (True, "ready", "exit_node"))
        self.assertIsNone(computers.record("work")["relay"])
        self.assertEqual(self.mac.config("work")["terminal"]["backend"], "cua")

    def test_a_reset_computer_is_pointed_again(self):
        computers = self.make({"state": "on", "port": 47610})
        computers.change("work", "on", "request-0004")
        computers.change("work", "reset", "request-0005")
        self.assertEqual([call[3] for call in self.calls], ["local:nollie-work", "local:nollie-work"])
        self.assertEqual(computers.status("work")["internet"], "relay")


class ScriptTests(unittest.TestCase):
    def test_only_the_port_is_filled_in(self):
        self.assertEqual(own.relay_script(50000), own.relay_script(47610).replace("47610", "50000"))
        self.assertIn("/etc/profile.d/nollie-relay.sh", own.relay_script(47610))
        self.assertTrue(own.relay_script(47610).rstrip().endswith("echo " + own.RELAY_MARKER))
        for bad in (80, 0, 70000, "47610; rm -rf /"):
            with self.assertRaises(ValueError):
                own.relay_script(bad)

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_the_snippet_sets_proxies_only_while_the_relay_answers(self):
        with TemporaryDirectory() as folder:
            tools = Path(folder) / "bin"
            tools.mkdir()
            # A computer whose default gateway is this machine's loopback.
            (tools / "ip").write_text("#!/bin/sh\necho 'default via 127.0.0.1 dev eth0 proto dhcp'\n")
            # A real time limit (perl's alarm), so a connection that hangs on a slow network still ends.
            (tools / "timeout").write_text("#!/bin/sh\nlimit=$1; shift\nexec perl -e 'alarm shift; exec @ARGV' \"$limit\" \"$@\"\n")
            for tool in ("ip", "timeout"):
                (tools / tool).chmod(0o755)
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
            snippet = Path(folder) / "relay.sh"
            snippet.write_text(own.relay_snippet(port))
            show = f'. "{snippet}"; printf "%s|%s|%s|%s" "$http_proxy" "$https_proxy" "$ALL_PROXY" "$NO_PROXY"'
            env = {"PATH": f"{tools}:/usr/bin:/bin", "HOME": folder}

            def run():
                return subprocess.run(["bash", "--noprofile", "--norc", "-c", show], env=env, capture_output=True,
                                      text=True, timeout=10).stdout

            self.assertEqual(run(), "|||")
            listener.listen(4)
            try:
                self.assertEqual(run(), f"http://127.0.0.1:{port}|http://127.0.0.1:{port}|socks5h://127.0.0.1:{port}"
                                        "|localhost,127.0.0.1,::1")
            finally:
                listener.close()
            self.assertEqual(run(), "|||")


FAKE_CUA = textwrap.dedent('''\
    import json, os, sys
    record = {"argv": sys.argv[1:], "telemetry": os.environ.get("CUA_TELEMETRY")}
    mode = os.environ["FAKE_MODE"]
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("method") == "initialize":
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": "2024-11-05"}}), flush=True)
        elif message.get("method") == "tools/call":
            record["call"] = message["params"]
            with open(os.environ["FAKE_RECORD"], "w") as out:
                json.dump(record, out)
            text = "nollie-relay-ready\\n" if mode != "silent" else "done\\n"
            result = {"content": [{"type": "text", "text": text}], "isError": mode == "error"}
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
            break
''')


class SpaceBashTests(unittest.TestCase):
    def run_fake(self, mode):
        with TemporaryDirectory() as folder:
            script = Path(folder) / "fake_cua.py"
            script.write_text(FAKE_CUA)
            cua = Path(folder) / "cua"
            cua.write_text(f"#!/bin/sh\nexec {sys.executable} -I {script} \"$@\"\n")
            cua.chmod(0o755)
            record = Path(folder) / "record.json"
            env = {"FAKE_MODE": mode, "FAKE_RECORD": str(record), "HOME": folder}
            done = own.default_space_bash(str(cua), Path(folder) / "cua.sock", env, "local:nollie-work", "echo hi",
                                          timeout=20)
            return done, json.loads(record.read_text()), folder

    def test_it_asks_cuas_mcp_server_for_space_bash_only(self):
        done, record, folder = self.run_fake("ok")
        self.assertTrue(done)
        self.assertEqual(record["argv"], ["--daemon", str(Path(folder) / "cua.sock"), "mcp", "--permissions", "spaces:space_bash"])
        self.assertEqual(record["telemetry"], "0")
        self.assertEqual(record["call"], {"name": "space_bash",
                                          "arguments": {"space": "local:nollie-work", "command": "echo hi", "timeout": 30}})

    def test_an_error_or_a_missing_marker_is_not_done(self):
        self.assertFalse(self.run_fake("error")[0])
        self.assertFalse(self.run_fake("silent")[0])

    def test_no_cua_is_not_done(self):
        self.assertFalse(own.default_space_bash("/nonexistent/cua", Path("/nonexistent.sock"), {}, "local:x", "true"))


if __name__ == "__main__":
    unittest.main()
