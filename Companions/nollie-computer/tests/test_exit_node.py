"""A Tailscale exit node on the Mac: helpers' computers get no internet, and the status says why.
The fixtures in Tests/Unit/Fixtures/Tailscale are shared with the app's own tests."""
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("own_computer_exit", ROOT / "Companions/nollie-computer/dashboard/own_computer.py")
own = importlib.util.module_from_spec(spec)
spec.loader.exec_module(own)
FIXTURES = ROOT / "Tests/Unit/Fixtures/Tailscale"

APP_TOOL = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
ROUTE_VIA_TAILSCALE = "   route to: default\ndestination: default\n       mask: default\n  interface: utun4\n      flags: <UP,DONE,STATIC>\n"
ROUTE_VIA_WIFI = "   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n"
UTUN4 = "utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\n\tinet 100.101.102.103 --> 100.101.102.103 netmask 0xffffffff\n"


def fixture(name):
    return (FIXTURES / f"tailscale-{name}.json").read_text()


class FakeCommands:
    def __init__(self, status=None, route=ROUTE_VIA_WIFI, tools=(APP_TOOL,)):
        self.status, self.route, self.tools, self.calls = status, route, set(tools), []

    def exists(self, path):
        return path in self.tools

    def run(self, argv, timeout, env=None):
        self.calls.append(argv)
        if argv[1:] == ["status", "--json"]:
            return (0, self.status) if self.status is not None else (1, "")
        if argv == ["/sbin/route", "-n", "get", "default"]:
            return 0, self.route
        if argv == ["/sbin/ifconfig", "utun4"]:
            return 0, UTUN4
        raise AssertionError(argv)


class ExitNodeTests(unittest.TestCase):
    def check(self, commands):
        return own.ExitNodeCheck(run=commands.run, exists=commands.exists, clock=lambda: 0)

    def test_status_with_an_exit_node_says_so(self):
        self.assertTrue(own.exit_node_from_status(fixture("exit-node")))
        self.assertTrue(self.check(FakeCommands(fixture("exit-node")))())

    def test_running_without_one_and_stopped_say_no(self):
        self.assertFalse(own.exit_node_from_status(fixture("running")))
        self.assertFalse(own.exit_node_from_status(fixture("stopped")))
        self.assertFalse(own.exit_node_from_status(fixture("needs-login")))
        self.assertIsNone(own.exit_node_from_status("not json"))
        self.assertFalse(self.check(FakeCommands(fixture("running")))())

    def test_without_the_command_line_the_default_route_decides(self):
        # The Mac App Store app may refuse to answer: the route on Tailscale's interface still tells.
        self.assertTrue(self.check(FakeCommands(None, route=ROUTE_VIA_TAILSCALE))())
        self.assertFalse(self.check(FakeCommands(None, route=ROUTE_VIA_WIFI))())
        self.assertFalse(self.check(FakeCommands(None, route=ROUTE_VIA_WIFI, tools=()))())

    def test_it_only_reads(self):
        commands = FakeCommands(fixture("exit-node"))
        self.check(commands)()
        for argv in commands.calls:
            self.assertIn(argv[1:], (["status", "--json"], ["-n", "get", "default"], ["utun4"]))

    def test_answers_are_kept_a_little_while(self):
        commands = FakeCommands(fixture("exit-node"))
        now = [0]
        check = own.ExitNodeCheck(run=commands.run, exists=commands.exists, clock=lambda: now[0])
        self.assertTrue(check())
        commands.status = fixture("running")
        self.assertTrue(check())
        now[0] = own.EXIT_NODE_TTL + 1
        self.assertFalse(check())

    def test_the_computer_status_carries_it(self):
        with TemporaryDirectory() as home:
            (Path(home) / ".cua").mkdir()
            on = own.OwnComputers(home=home, run=lambda argv, timeout, env=None: (None, ""), hermes="/fake/hermes",
                                  cua="/fake/cua", homes=lambda p: Path(home), exit_node=lambda: True)
            self.assertEqual(on.status("default")["internet"], "exit_node")
            off = own.OwnComputers(home=home, run=lambda argv, timeout, env=None: (None, ""), hermes="/fake/hermes",
                                   cua="/fake/cua", homes=lambda p: Path(home), exit_node=lambda: False)
            self.assertIsNone(off.status("default")["internet"])


if __name__ == "__main__":
    unittest.main()
