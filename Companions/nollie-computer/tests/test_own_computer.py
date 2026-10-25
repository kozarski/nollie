import importlib.util
import os
import shutil
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

spec = importlib.util.spec_from_file_location("own_computer", Path(__file__).resolve().parents[1] / "dashboard/own_computer.py")
own = importlib.util.module_from_spec(spec)
spec.loader.exec_module(own)

SETTINGS = "plugins.entries.cua-spaces.settings"


class FakeMac:
    """Cua's CLI and Hermes's CLI as this module calls them, over files in a temporary home."""

    def __init__(self, home, version="cua 0.5.0", runtime_ready=True, create_works=True):
        self.home = Path(home)
        self.version = version
        self.runtime_ready = runtime_ready
        self.create_works = create_works
        self.spaces = {}
        self.calls = []
        (self.home / ".cua").mkdir(parents=True)
        (self.home / ".cua/cua.sock").write_text("")

    def profile_home(self, profile):
        path = self.home / ".hermes" if profile == "default" else self.home / ".hermes/profiles" / profile
        path.mkdir(parents=True, exist_ok=True)
        return path

    def config(self, profile):
        path = self.profile_home(profile) / "config.yaml"
        return json.loads(path.read_text()) if path.exists() else {}

    def save(self, profile, config):
        (self.profile_home(profile) / "config.yaml").write_text(json.dumps(config))

    def run(self, argv, timeout, env=None):
        self.calls.append(argv)
        if argv[0] == "/fake/cua":
            assert env == {"HOME": str(self.home)}, env
            return self.cua(argv[1:])
        assert argv[:2] == ["/fake/hermes", "--profile"], argv
        return self.hermes(argv[2], argv[3:])

    def cua(self, args):
        if args == ["--version"]:
            return 0, self.version
        if args[:2] == ["--daemon", str(self.home / ".cua/cua.sock")]:
            args = args[2:]
            assert args[0] == "--json"
            if args[1:] == ["runtime", "doctor"]:
                return 0, json.dumps({"backends": [{"backend": "managed", "ready": self.runtime_ready},
                                                   {"backend": "container", "ready": False}]})
            if args[1:] == ["spaces", "ls"]:
                return 0, json.dumps({"spaces": list(self.spaces.values())})
        if args[:5] == ["spaces", "create", "linux", "--on", "local"] and args[5] == "--name":
            if not self.create_works:
                return 1, ""
            self.spaces[args[6]] = {"id": "local:" + args[6], "name": args[6], "power_state": "running"}
            return 0, "{}"
        if args[:2] == ["spaces", "delete"] and args[3] == "--force":
            self.spaces.pop(args[2].split(":", 1)[1], None)
            return 0, ""
        raise AssertionError(args)

    def hermes(self, profile, args):
        config = self.config(profile)
        if args[:2] == ["plugins", "install"]:
            assert args[2:] == [own.PLUGIN_URL, "--ref", own.PLUGIN_REF, "--force", "--enable", "--yes-deps"], args
            folder = self.profile_home(profile) / "plugins/cua-spaces"
            folder.mkdir(parents=True)
            (folder / "plugin.yaml").write_text("name: cua-spaces\n")
            args = ["plugins", "enable", "cua-spaces"]
        if args[:2] == ["plugins", "enable"]:
            plugins = config.setdefault("plugins", {})
            plugins["enabled"] = sorted(set(plugins.get("enabled", [])) | {args[2]})
        elif args[:2] == ["plugins", "disable"]:
            plugins = config.setdefault("plugins", {})
            plugins["enabled"] = [name for name in plugins.get("enabled", []) if name != args[2]]
        elif args[:2] == ["config", "set"]:
            *parents, last = args[2].split(".")
            node = config
            for part in parents:
                node = node.setdefault(part, {})
            node[last] = {"false": False, "true": True}.get(args[3], args[3])
        elif args[:2] == ["config", "unset"]:
            *parents, last = args[2].split(".")
            node = config
            for part in parents:
                node = node.get(part, {})
            node.pop(last, None)
        else:
            raise AssertionError(args)
        self.save(profile, config)
        return 0, ""


class OwnComputerTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.mac = FakeMac(self.directory.name)
        self.private = {"private"}
        self.make()

    def tearDown(self):
        self.directory.cleanup()

    def make(self):
        self.computers = own.OwnComputers(home=self.mac.home, run=self.mac.run, hermes="/fake/hermes", cua="/fake/cua",
                                          homes=self.mac.profile_home, private=lambda p: p in self.private,
                                          spawn=lambda work: work(), yaml_load=json.loads)

    def owned(self):
        return json.loads((self.mac.home / ".hermes/nollie-computer/owned-spaces.json").read_text())["profiles"]

    def test_turning_on_installs_the_pinned_plugin_makes_the_named_computer_and_switches_last(self):
        self.mac.save("work", {"terminal": {"backend": "docker"}, "model": {"default": "kept"}})
        status = self.computers.change("work", "on", "request-0001")
        self.assertEqual((status["on"], status["state"], status["computer_name"]), (True, "ready", "nollie-work"))
        config = self.mac.config("work")
        self.assertEqual(config["terminal"]["backend"], "cua")
        self.assertEqual(config["model"], {"default": "kept"})
        self.assertEqual(config["plugins"]["entries"]["cua-spaces"]["settings"],
                         {"space": "nollie-work", "on": "local", "image": "linux", "delete_on_exit": False})
        self.assertIn("cua-spaces", config["plugins"]["enabled"])
        self.assertEqual(self.owned(), {"work": "local:nollie-work"})
        hermes = [c for c in self.mac.calls if c[0] == "/fake/hermes"]
        self.assertEqual(hermes[-1][3:], ["config", "set", "terminal.backend", "cua"])
        create = next(i for i, c in enumerate(self.mac.calls) if c[1:3] == ["spaces", "create"])
        backend = next(i for i, c in enumerate(self.mac.calls) if c[-2:] == ["terminal.backend", "cua"])
        self.assertLess(create, backend)
        self.assertTrue(all(c[1:3] == ["--profile", "work"] for c in hermes))
        self.assertEqual(len(list(self.mac.profile_home("work").glob("config.yaml.bak-nollie-computer-*"))), 1)
        self.assertEqual(self.mac.config("default"), {})

    def test_turning_off_puts_back_exactly_what_was_there_and_keeps_the_computer(self):
        before = {"terminal": {"backend": "docker"}, "plugins": {"enabled": ["other"]}}
        self.mac.save("work", before)
        self.computers.change("work", "on", "request-0001")
        status = self.computers.change("work", "off", "request-0002")
        self.assertEqual(self.mac.config("work")["terminal"], {"backend": "docker"})
        self.assertEqual(self.mac.config("work")["plugins"]["enabled"], ["other"])
        self.assertNotIn("space", self.mac.config("work")["plugins"]["entries"]["cua-spaces"]["settings"])
        self.assertEqual((status["on"], status["state"], status["has_computer"]), (False, "off", True))
        self.assertIn("nollie-work", self.mac.spaces)
        self.assertEqual(self.owned(), {"work": "local:nollie-work"})
        self.assertFalse(any(c[1:3] == ["spaces", "delete"] for c in self.mac.calls))

    def test_turning_off_a_helper_without_a_terminal_setting_removes_the_one_it_added(self):
        self.computers.change("work", "on", "request-0001")
        self.computers.change("work", "off", "request-0002")
        self.assertNotIn("backend", self.mac.config("work").get("terminal", {}))

    def test_an_answer_lost_on_the_way_never_repeats_the_change(self):
        self.computers.change("work", "on", "request-0001")
        installs = sum(c[3:5] == ["plugins", "install"] for c in self.mac.calls)
        self.computers.change("work", "on", "request-0001")
        self.assertEqual(sum(c[3:5] == ["plugins", "install"] for c in self.mac.calls), installs)
        self.assertEqual(sum(c[1:3] == ["spaces", "create"] for c in self.mac.calls), 1)

    def test_private_and_unknown_names_are_refused_before_anything_is_read(self):
        for name in ("private", "../default", "Work"):
            with self.assertRaises(own.Refused):
                self.computers.status(name)
            with self.assertRaises(own.Refused):
                self.computers.change(name, "on", "request-0001")
        self.assertEqual(self.mac.calls, [])

    def test_unreadable_private_list_refuses(self):
        def broken(profile):
            raise ValueError("damaged")
        self.computers.private = broken
        with self.assertRaises(own.Refused):
            self.computers.status("work")

    def test_setup_says_what_cua_still_needs(self):
        self.assertEqual(self.computers.status("work")["setup"], "ready")
        self.mac.runtime_ready = False
        self.assertEqual(self.computers.status("work")["setup"], "no_runtime")
        self.mac.version = "cua 0.4.1"
        status = self.computers.status("work")
        self.assertEqual((status["setup"], status["cua_version"]), ("old_cua", "0.4.1"))
        self.mac.version = "cua 0.5.0"
        (self.mac.home / ".cua/cua.sock").unlink()
        self.assertEqual(self.computers.status("work")["setup"], "cua_not_running")
        self.computers.cua = None
        self.computers.find = lambda home: None
        self.assertEqual(self.computers.status("work")["setup"], "no_cua")
        with self.assertRaises(own.Refused):
            self.computers.change("work", "on", "request-0001")

    def test_reads_only_talk_to_a_running_daemon(self):
        self.computers.status("work")
        for call in self.mac.calls:
            self.assertTrue(call[1:] == ["--version"] or call[1:3] == ["--daemon", str(self.mac.home / ".cua/cua.sock")], call)

    def test_a_computer_that_could_not_be_made_needs_you_and_the_terminal_is_unchanged(self):
        self.mac.save("work", {"terminal": {"backend": "local"}})
        self.mac.create_works = False
        status = self.computers.change("work", "on", "request-0001")
        self.assertEqual((status["on"], status["state"]), (True, "needs_you"))
        self.assertIn("Try again", status["message"])
        self.assertEqual(self.mac.config("work")["terminal"]["backend"], "local")
        self.mac.create_works = True
        status = self.computers.change("work", "on", "request-0002")
        self.assertEqual(status["state"], "ready")
        self.computers.change("work", "off", "request-0003")
        self.assertEqual(self.mac.config("work")["terminal"]["backend"], "local")

    def test_a_stopped_computer_is_asleep(self):
        self.computers.change("work", "on", "request-0001")
        self.mac.spaces["nollie-work"]["power_state"] = "suspended"
        self.assertEqual(self.computers.status("work")["state"], "asleep")
        del self.mac.spaces["nollie-work"]
        self.assertEqual(self.computers.status("work")["state"], "needs_you")

    def test_remove_asks_for_the_switch_off_first_then_keeps_other_owners(self):
        owned = self.mac.home / ".hermes/nollie-computer/owned-spaces.json"
        owned.parent.mkdir(parents=True)
        owned.write_text(json.dumps({"version": 1, "profiles": {"forager": "local:forager-desk"}}))
        self.computers.change("work", "on", "request-0001")
        with self.assertRaises(own.Refused):
            self.computers.change("work", "remove", "request-0002")
        self.computers.change("work", "off", "request-0003")
        status = self.computers.change("work", "remove", "request-0004")
        self.assertEqual((status["has_computer"], status["computer_name"]), (False, None))
        self.assertNotIn("nollie-work", self.mac.spaces)
        self.assertEqual(self.owned(), {"forager": "local:forager-desk"})
        self.assertEqual(owned.stat().st_mode & 0o777, 0o600)

    def test_reset_makes_a_fresh_computer_with_the_same_name(self):
        self.computers.change("work", "on", "request-0001")
        self.mac.spaces["nollie-work"]["marker"] = "old"
        status = self.computers.change("work", "reset", "request-0002")
        self.assertEqual(status["state"], "ready")
        self.assertNotIn("marker", self.mac.spaces["nollie-work"])
        self.assertEqual(self.mac.config("work")["terminal"]["backend"], "cua")

    def test_reset_needs_the_switch_on(self):
        with self.assertRaises(own.Refused):
            self.computers.change("work", "reset", "request-0001")

    def test_a_change_in_progress_shows_as_getting_ready_and_blocks_another(self):
        pending = []
        self.computers.spawn = pending.append
        status = self.computers.change("work", "on", "request-0001")
        self.assertEqual((status["on"], status["state"], status["busy"]), (True, "getting_ready", True))
        with self.assertRaises(own.Refused):
            self.computers.change("work", "off", "request-0002")
        pending[0]()
        self.assertEqual(self.computers.status("work")["state"], "ready")

    def test_version_parsing(self):
        self.assertEqual(own.parse_version("cua 0.5.0"), (0, 5, 0))
        self.assertEqual(own.parse_version("cua 0.10.2-beta.1"), (0, 10, 2))
        self.assertIsNone(own.parse_version("cua"))


try:
    import fastapi
    from fastapi.testclient import TestClient
except ImportError:
    fastapi = None


@unittest.skipIf(fastapi is None, "fastapi is not installed")
class OwnComputerRouteTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.mac = FakeMac(self.directory.name)
        route_spec = importlib.util.spec_from_file_location("own_computer_routes", Path(__file__).resolve().parents[1] / "dashboard/plugin_api.py")
        self.api = importlib.util.module_from_spec(route_spec)
        route_spec.loader.exec_module(self.api)
        self.api._computers = own.OwnComputers(home=self.mac.home, run=self.mac.run, hermes="/fake/hermes", cua="/fake/cua",
                                               homes=self.mac.profile_home, private=lambda p: p == "private",
                                               spawn=lambda work: work(), yaml_load=json.loads)
        self.api._own.Refused = own.Refused
        app = fastapi.FastAPI()
        app.include_router(self.api.router)
        self.client = TestClient(app)

    def tearDown(self):
        self.directory.cleanup()

    def test_status_change_and_refusals(self):
        read = self.client.get("/own-computer", params={"profile": "work"})
        self.assertEqual(read.status_code, 200)
        self.assertEqual(read.headers["cache-control"], "no-store")
        self.assertEqual((read.json()["on"], read.json()["setup"]), (False, "ready"))
        changed = self.client.post("/own-computer", json={"profile": "work", "action": "on", "request_id": "request-0001"})
        self.assertEqual((changed.status_code, changed.json()["state"]), (200, "ready"))
        self.assertEqual(self.client.get("/own-computer", params={"profile": "private"}).status_code, 404)
        busy = self.client.post("/own-computer", json={"profile": "work", "action": "remove", "request_id": "request-0002"})
        self.assertEqual(busy.status_code, 409)
        self.assertEqual(busy.json()["detail"], "Turn its computer off first.")
        self.assertEqual(self.client.post("/own-computer", json={"profile": "work", "action": "on"}).status_code, 422)


class ReleaseBeforeRemovalTests(unittest.TestCase):
    """Remove Nollie: each helper's settings go back, then the computer Nollie made is deleted."""

    setUp = OwnComputerTests.setUp
    tearDown = OwnComputerTests.tearDown
    make = OwnComputerTests.make
    owned = OwnComputerTests.owned

    def turn_on(self, profile, before=None):
        self.mac.save(profile, before or {"terminal": {"backend": "docker"}})
        self.computers.change(profile, "on", "request-" + profile.ljust(8, "0"))
        self.assertEqual(self.mac.config(profile)["terminal"]["backend"], "cua")

    def test_settings_go_back_then_the_computer_is_deleted(self):
        self.turn_on("work")
        report = self.computers.release()
        self.assertEqual(report["profiles"]["work"], {"turned_off": True, "computer": "deleted", "message": None})
        self.assertEqual(self.mac.config("work")["terminal"]["backend"], "docker")
        self.assertEqual(self.mac.spaces, {})
        self.assertEqual(self.owned(), {})
        self.assertIsNone(self.computers.record("work"))

    def test_a_managed_setup_being_deleted_only_loses_its_computers(self):
        self.turn_on("work")
        before = len([c for c in self.mac.calls if c[0] == "/fake/hermes"])
        report = self.computers.release(spaces_only=True)
        self.assertEqual(report["profiles"]["work"]["computer"], "deleted")
        self.assertFalse(report["profiles"]["work"]["turned_off"])
        self.assertEqual(len([c for c in self.mac.calls if c[0] == "/fake/hermes"]), before)

    def test_when_cua_does_not_answer_the_computer_and_its_record_stay(self):
        self.turn_on("work")
        (self.mac.home / ".cua/cua.sock").unlink()
        report = self.computers.release()
        self.assertEqual(report["profiles"]["work"]["computer"], "kept")
        self.assertIn("Cua didn't answer", report["profiles"]["work"]["message"])
        self.assertEqual(self.owned(), {"work": "local:nollie-work"})
        self.assertIn("nollie-work", self.mac.spaces)

    def test_a_computer_nollie_did_not_name_is_never_deleted(self):
        self.mac.spaces["custom"] = {"id": "local:custom", "name": "custom", "power_state": "running"}
        folder = self.mac.home / ".hermes/nollie-computer"
        folder.mkdir(parents=True)
        (folder / "owned-spaces.json").write_text(json.dumps({"version": 1, "profiles": {"work": "local:custom"}}))
        report = self.computers.release()
        self.assertEqual(report["profiles"]["work"]["computer"], "none")
        self.assertIn("custom", self.mac.spaces)
        self.assertFalse(any(c[1:3] == ["spaces", "delete"] for c in self.mac.calls))

    def test_a_helper_that_cannot_be_switched_back_keeps_its_computer(self):
        self.turn_on("work")
        real = self.mac.run

        def failing(argv, timeout, env=None):
            if argv[0] == "/fake/hermes":
                self.mac.calls.append(argv)
                return 1, ""
            return real(argv, timeout, env)
        self.computers.run = failing
        report = self.computers.release()
        self.assertEqual(report["profiles"]["work"]["computer"], "kept")
        self.assertIn("nollie-work", self.mac.spaces)
        self.assertIsNotNone(report["profiles"]["work"]["message"])

    def test_the_command_prints_one_report(self):
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(own.main(["release", "--home", str(self.mac.home), "--cua-home", str(self.mac.home), "--spaces-only"]), 0)
        self.assertEqual(json.loads(out.getvalue()), {"profiles": {}, "version": 1})


class FindsCuaByFullPath(unittest.TestCase):
    """Cua's tool is called by its full path inside the app in use: no ~/.local/bin link from Nollie."""

    def make_tool(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n")
        path.chmod(0o755)
        return path

    def test_nollie_runtime_names_the_copy_in_use(self):
        with TemporaryDirectory() as home:
            home = Path(home)
            tool = self.make_tool(home / "Library/Application Support/Nollie/Cua" / own.CUA_TOOL)
            self.assertEqual(own_module_find(home, {"NOLLIE_CUA_CLI": str(tool), "PATH": ""}), str(tool))

    def test_a_named_path_that_is_not_cua_inside_the_app_is_ignored(self):
        with TemporaryDirectory() as home:
            home = Path(home)
            other = self.make_tool(home / "bin/cua")
            evil = self.make_tool(home / "x/Cua Spaces.app/Contents/MacOS/Cua Spaces")
            for named in (str(other), str(evil), "relative/" + own.CUA_TOOL, str(home / "a/../") + "/" + own.CUA_TOOL):
                self.assertNotIn(Path(named), own.cua_candidates(home, {"NOLLIE_CUA_CLI": named})[:1])

    def test_without_a_name_nollies_own_folder_is_used_and_the_persons_comes_first(self):
        with TemporaryDirectory() as home:
            home = Path(home)
            mine = self.make_tool(home / "Library/Application Support/Nollie/Cua" / own.CUA_TOOL)
            candidates = own.cua_candidates(home, {})
            self.assertLess(candidates.index(home / "Applications" / own.CUA_TOOL), candidates.index(mine))
            self.assertEqual(candidates[0], Path("/Applications") / own.CUA_TOOL)
            if not os.access(Path("/Applications") / own.CUA_TOOL, os.X_OK) and not shutil.which("cua"):
                self.assertEqual(own_module_find(home, {}), str(mine))

    def test_the_computer_add_on_only_ever_runs_cua_and_hermes(self):
        with TemporaryDirectory() as home:
            mac = FakeMac(home)
            computers = own.OwnComputers(home=home, run=mac.run, hermes="/fake/hermes", cua="/fake/cua",
                                         homes=mac.profile_home, spawn=lambda work: work(), yaml_load=json.loads)
            computers.change("scout", "on", "request-00000001")
            computers.change("scout", "off", "request-00000002")
            computers.change("scout", "remove", "request-00000003")
            self.assertTrue(mac.calls)
            for argv in mac.calls:
                self.assertIn(argv[0], ("/fake/cua", "/fake/hermes"))
                self.assertNotIn("open", argv)


def own_module_find(home, environ):
    return own.find_cua(home, environ)


if __name__ == "__main__":
    unittest.main()
