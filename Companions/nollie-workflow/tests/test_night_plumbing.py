"""The installer's --recorder, register() per profile, and control.py's two switches."""
import importlib.util
import inspect
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from night_support import NAME, load

# The Mac's calendar, reminders and contacts, registered in this order for every bot that is not private.
APPLE_TOOLS = list(load("apple_data").TOOLS)
PAYMENT_TOOLS = ["request_payment", "payment_cards"]

ROOT = Path(__file__).resolve().parents[1]


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


installer = module("install.py", "workflow_night_installer")
control = module("control.py", "workflow_night_control")


class RecorderInstallTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.hermes = self.home / ".hermes"
        (self.hermes / "hermes-agent/hermes_cli").mkdir(parents=True)
        for profile in ("career", "nowhere", "private", "moss"):
            (self.hermes / "profiles" / profile).mkdir(parents=True)
            (self.hermes / "profiles" / profile / "config.yaml").write_text("x: 1\n")
        (self.hermes / "profiles" / "half-made").mkdir()

    def run_installer(self, *argv):
        commands = []

        def run(command, **kwargs):
            commands.append(command)
            return SimpleNamespace(returncode=0)
        with patch.object(Path, "home", return_value=self.home), patch("sys.argv", ["install.py", *argv]), \
                patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                patch.object(installer.subprocess, "run", side_effect=run), patch("builtins.print") as printed:
            installer.main()
        return commands, " ".join(str(c.args[0]) for c in printed.call_args_list)

    def test_plan_only_by_default(self):
        commands, said = self.run_installer("--recorder")
        self.assertEqual(commands, [])
        self.assertIn("career, nowhere", said)
        self.assertNotIn("moss", said.replace("Never a private one", ""))
        self.assertFalse((self.hermes / "plugins").exists())
        self.assertFalse((self.hermes / "profiles/career/plugins").exists())

    def test_followed_profiles_only_never_private(self):
        commands, _ = self.run_installer("--apply", "--recorder")
        self.assertEqual(commands, [["/fixed/hermes", "--profile", "career", "plugins", "enable", "nollie-workflow"],
                                    ["/fixed/hermes", "--profile", "nowhere", "plugins", "enable", "nollie-workflow"]])
        for profile in ("career", "nowhere"):
            self.assertTrue((self.hermes / "profiles" / profile / "plugins/nollie-workflow/recorder.py").exists())
            self.assertFalse((self.hermes / "profiles" / profile / "plugins/nollie-workflow/tests").exists())
        for profile in ("private", "moss", "half-made"):
            self.assertFalse((self.hermes / "profiles" / profile / "plugins").exists())
        self.assertTrue((self.hermes / "plugins/nollie-workflow/night_service.py").exists())

    def test_the_saved_private_list_decides_and_private_is_never_included(self):
        (self.hermes / "nollie-private-bots.json").write_text(json.dumps({"version": 1, "profiles": ["nowhere"]}))
        commands, _ = self.run_installer("--apply", "--recorder")
        # moss is carried over as private whatever the saved list says, as Papertrail's installer has it.
        self.assertEqual([c[2] for c in commands], ["career"])
        self.assertFalse((self.hermes / "profiles/private/plugins").exists())

    def test_a_damaged_private_list_installs_no_recorder(self):
        (self.hermes / "nollie-private-bots.json").write_text("{")
        with self.assertRaises(SystemExit):
            self.run_installer("--apply", "--recorder")
        self.assertFalse((self.hermes / "profiles/career/plugins").exists())

    def test_a_profile_whose_name_holds_a_private_one_gets_no_recorder(self):
        for profile in ("moss-notes", "career-old"):
            (self.hermes / "profiles" / profile).mkdir()
            (self.hermes / "profiles" / profile / "config.yaml").write_text("x: 1\n")
        load("private_bots").save(self.hermes, ["career"])
        self.assertEqual(installer.followed_profiles(ROOT, self.hermes), ["nowhere"])

    def papertrail_hooks(self, profile, number):
        """What the copy installed in this bot registers for Papertrail, loaded as Hermes would load it."""
        copy = self.hermes / "profiles" / profile / "plugins" / "nollie-workflow"
        name = f"workflow_installed_copy_{profile}_{number}"
        spec = importlib.util.spec_from_file_location(name, copy / "__init__.py", submodule_search_locations=[str(copy)])
        package = importlib.util.module_from_spec(spec)
        hooks = []
        ctx = SimpleNamespace(profile_name=profile, register_hook=lambda hook, fn: hooks.append(hook))
        modules = {name: package, "hermes_constants": SimpleNamespace(get_hermes_home=lambda: copy.parent.parent)}
        with patch.dict(sys.modules, modules):
            spec.loader.exec_module(package)
            package._register_papertrail(ctx, profile, self.hermes)
        return hooks

    def test_every_recorder_copy_keeps_a_papertrail(self):
        _, said = self.run_installer("--recorder", "--papertrail-bots", "career")
        self.assertIn("Recorder and Papertrail: career, nowhere.", said)
        self.run_installer("--apply", "--recorder")
        for profile in ("career", "nowhere"):
            self.assertFalse((self.hermes / "profiles" / profile / "plugins/nollie-workflow/recorder-only").exists())
        self.assertEqual(self.papertrail_hooks("career", 1), list(load("papertrail").HOOKS))
        # A marker an older installer left no longer turns Papertrail off.
        marker = self.hermes / "profiles/nowhere/plugins/nollie-workflow/recorder-only"
        marker.write_text("Papertrail is off in this bot.\n")
        self.assertEqual(self.papertrail_hooks("nowhere", 2), list(load("papertrail").HOOKS))
        # An upgrade replaces the copy, and the old marker goes with it.
        self.run_installer("--apply", "--recorder")
        self.assertFalse(marker.exists())

    def test_upgrade_backs_up_a_previous_recorder(self):
        self.run_installer("--apply", "--recorder")
        self.run_installer("--apply", "--recorder")
        self.assertTrue(list((self.hermes / "profiles/career/plugin-backups").glob("nollie-workflow-*")))

    def test_recorder_copies_still_hold_sending(self):
        self.run_installer("--apply", "--recorder")
        for profile in ("career", "nowhere"):
            (self.hermes / "profiles" / profile / "config.yaml").write_text(
                json.dumps({"plugins": {"enabled": ["nollie-workflow"]}}))
            copy = self.hermes / "profiles" / profile / "plugins" / "nollie-workflow"
            name = f"workflow_ask_first_copy_{profile}"
            spec = importlib.util.spec_from_file_location(name, copy / "__init__.py", submodule_search_locations=[str(copy)])
            package = importlib.util.module_from_spec(spec)
            hooks = []
            ctx = SimpleNamespace(profile_name=profile, register_hook=lambda hook, fn: hooks.append((hook, fn)),
                                  current_cron_execution=lambda: None)
            with patch.dict(sys.modules, {name: package}):
                spec.loader.exec_module(package)
                package._register_ask_first(ctx, profile, self.hermes)
                decisions = [fn(tool_name="send_message", args={"message": "Hello"})
                             for hook, fn in hooks if hook == "pre_tool_call"]
            self.assertEqual(len(decisions), 2)
            self.assertIsNone(decisions[0])
            self.assertEqual(decisions[1]["action"], "block")
            self.assertIn("Held for the person's yes", decisions[1]["message"])


class RegisterTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.bot_home = self.home
        profiles = SimpleNamespace(get_profile_dir=lambda name: self.home if name == "default" else self.fail(name))
        constants = SimpleNamespace(get_hermes_home=lambda: self.bot_home)
        modules = patch.dict(sys.modules, {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles,
                                           "hermes_constants": constants})
        modules.start()
        self.addCleanup(modules.stop)
        self.package = sys.modules[NAME]

    def register(self, profile):
        self.bot_home = self.home if profile == "default" else self.home / "profiles" / profile
        self.bot_home.mkdir(parents=True, exist_ok=True)
        hooks, tools, unload = [], [], []
        ctx = SimpleNamespace(profile_name=profile, register_hook=lambda name, fn: hooks.append(name),
                              register_tool=lambda **kw: tools.append(kw["name"]), on_unload=unload.append,
                              current_cron_execution=lambda: None)
        started = []
        with patch.object(load("service"), "start", side_effect=lambda home, c: started.append(home)):
            self.package.register(ctx)
        return hooks, tools, started

    def test_default_keeps_todays_behaviour_and_adds_the_recorder(self):
        hooks, tools, started = self.register("default")
        self.assertIn("pre_tool_call", hooks)
        # Not installed yet: no follow-through. Saved sign-ins and the Mac's calendar, reminders and contacts
        # load for every bot that is not private.
        self.assertEqual((tools, started), (["request_sign_in", *APPLE_TOOLS, *PAYMENT_TOOLS], []))
        (self.home / "nollie-workflow").mkdir(exist_ok=True)
        load("workflow_core").atomic_write(self.home / "nollie-workflow/state.json", load("workflow_core").initial_state())
        hooks, tools, started = self.register("default")
        self.assertEqual((tools, started),
                         (["nollie_followup", "request_sign_in", *APPLE_TOOLS, *PAYMENT_TOOLS], [self.home.resolve()]))
        # The picture pause and Ask first, then the recorder's guard and its record of the call.
        self.assertEqual(hooks.count("pre_tool_call"), 4)

    def test_other_profiles_get_papertrail_and_the_recorder_but_not_the_board(self):
        hooks, tools, started = self.register("career")
        self.assertEqual((tools, started), (["request_sign_in", *APPLE_TOOLS, *PAYMENT_TOOLS], []))
        self.assertEqual(hooks.count("pre_tool_call"), 4)
        # The recordings Ask first's pause keeps track of, its memory of the latest screen, Papertrail, and the
        # recorder.
        self.assertEqual(hooks.count("post_tool_call"), 4)
        self.assertEqual(hooks.count("transform_tool_result"), 1)
        self.assertTrue(set(load("papertrail").HOOKS) <= set(hooks))
        self.assertTrue((self.home / "nollie-workflow/recorders/career.json").exists())
        self.assertTrue((self.home / "profiles/career/nollie-workflow/papertrail").is_dir())

    def test_papertrail_failing_still_registers_the_recorder(self):
        with patch.object(load("papertrail"), "Recorder", side_effect=RuntimeError("broken")), \
                self.assertLogs("nollie-workflow", "WARNING") as logged:
            hooks, _, _ = self.register("career")
        self.assertEqual((hooks.count("pre_tool_call"), hooks.count("post_tool_call")), (4, 3))
        self.assertNotIn("post_api_request", hooks)
        self.assertIn("Papertrail did not start: RuntimeError", logged.output[0])

    def test_the_recorder_failing_still_registers_papertrail(self):
        with patch.object(load("recorder"), "register", side_effect=RuntimeError("broken")), \
                self.assertLogs("nollie-workflow", "WARNING") as logged:
            hooks, _, _ = self.register("career")
        self.assertEqual(hooks, ["pre_tool_call", "transform_tool_result", "post_tool_call", "pre_tool_call",
                                 "post_tool_call"] + list(load("papertrail").HOOKS))
        self.assertIn("The Night shift recorder did not start: RuntimeError", logged.output[0])

    def test_private_profiles_get_nothing(self):
        for profile in ("private", "moss"):
            self.assertEqual(self.register(profile), ([], [], []))
        load("private_bots").save(self.home, ["career"])
        self.assertEqual(self.register("career"), ([], [], []))
        self.assertEqual(self.register("private"), ([], [], []))
        (self.home / "nollie-private-bots.json").write_text("{")
        # A damaged list: only the stand-in that refuses risky calls, and nothing at all for the bots that are
        # always private.
        self.assertEqual(self.register("nowhere"), (["pre_tool_call"], [], []))
        for profile in ("private", "moss"):
            self.assertEqual(self.register(profile), ([], [], []), profile)

    def test_private_main_bot_never_starts_board_follow_through(self):
        root = self.home / "nollie-workflow"
        root.mkdir()
        load("workflow_core").atomic_write(root / "state.json", load("workflow_core").initial_state())
        load("private_bots").save(self.home, ["default"])
        before = {path.relative_to(self.home): path.read_bytes() for path in self.home.rglob("*") if path.is_file()}
        self.assertEqual(self.register("default"), ([], [], []))
        self.assertEqual({path.relative_to(self.home): path.read_bytes() for path in self.home.rglob("*") if path.is_file()}, before)

    def test_damaged_private_list_never_starts_board_follow_through(self):
        root = self.home / "nollie-workflow"
        root.mkdir()
        load("workflow_core").atomic_write(root / "state.json", load("workflow_core").initial_state())
        (self.home / "nollie-private-bots.json").write_text("{")
        self.assertEqual(self.register("default"), (["pre_tool_call"], [], []))


class AskFirstRegistrationTests(unittest.TestCase):
    """The picture pause and Ask first, in that order, before every other hook, and what stands in if they fail."""

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.package = sys.modules[NAME]

    def register(self, profile="career"):
        hooks = []
        ctx = SimpleNamespace(profile_name=profile, register_hook=lambda name, fn: hooks.append((name, fn)),
                              current_cron_execution=lambda: None)
        self.package._register_ask_first(ctx, profile, self.home)
        return hooks

    @staticmethod
    def ask_first(hooks):
        return next(inspect.unwrap(fn).__self__ for _, fn in hooks
                    if isinstance(getattr(inspect.unwrap(fn), "__self__", None), load("ask_first").AskFirst))

    def filling(self):
        folder = self.home / "nollie-workflow" / "sign-ins" / "requests"
        folder.mkdir(parents=True, exist_ok=True)
        now = int(time.time())
        (folder / ("a" * 32 + ".json")).write_text(json.dumps({
            "version": 1, "id": "a" * 32, "bot": "career", "site": "example.com", "computer": "local:dev",
            "state": "filling", "created_at": now, "updated_at": now}))
        return folder / ("a" * 32 + ".json")

    def test_the_pause_first_then_ask_first_then_the_screen_memory(self):
        hooks = self.register()
        sign_ins = load("sign_ins")
        self.assertEqual([name for name, _ in hooks], ["pre_tool_call", "transform_tool_result", "post_tool_call",
                                                       "pre_tool_call", "post_tool_call"])
        pause = hooks[0][1].__self__
        self.assertIsInstance(pause, sign_ins.PicturePause)
        self.assertEqual(hooks[0][1], pause.hook)
        self.assertEqual(hooks[1][1], pause.result)
        self.assertEqual(hooks[2][1], sign_ins.RECORDINGS.post_tool_call)
        self.assertIsInstance(inspect.unwrap(hooks[3][1]).__self__, load("ask_first").AskFirst)
        self.assertIsInstance(hooks[4][1].__self__, load("screen_text").Memory)
        # Ask first reads the screen through the same memory the post hook fills.
        self.assertIs(self.ask_first(hooks).screen.memory, hooks[4][1].__self__)

    def test_private_bots_get_neither(self):
        for profile in ("private", "moss", ""):
            self.assertEqual(self.register(profile), [], profile)
        load("private_bots").save(self.home, ["career"])
        self.assertEqual(self.register("career"), [])
        (self.home / "nollie-private-bots.json").write_text("{")
        self.assertEqual(self.register("nowhere"), [("pre_tool_call", self.package._refuse_unguarded)])

    def test_a_running_bot_follows_its_ask_first_choice(self):
        bot_home = self.home / "profiles" / "career"
        bot_home.mkdir(parents=True)
        config = bot_home / "config.yaml"
        config.write_text(json.dumps({"plugins": {"enabled": ["nollie-workflow"]}}))
        hooks = self.register()
        hook = hooks[3][1]
        call = {"tool_name": "send_message", "args": {"message": "Hello"}}
        self.assertEqual(hook(**call)["action"], "block")
        for plugins in ({"enabled": ["nollie-workflow"], "disabled": ["nollie-workflow"]},
                        {"enabled": ["nollie-workflow"], "disabled": ["plugins/nollie-workflow"]},
                        {"enabled": []}, {}):
            config.write_text(json.dumps({"plugins": plugins}))
            self.assertIsNone(hook(**call))
        config.write_text(json.dumps({"plugins": {"enabled": ["plugins/nollie-workflow"]}}))
        self.assertEqual(hook(**call)["action"], "block")

    def test_unreadable_settings_never_mean_ask_first_is_off(self):
        bot_home = self.home / "profiles" / "career"
        bot_home.mkdir(parents=True)
        config = bot_home / "config.yaml"
        hook = self.register()[3][1]
        for text in ('{"plugins":{"enabled":null}}', '[]', '{'):
            config.write_text(text)
            self.assertEqual(hook(tool_name="send_message", args={})["action"], "block")
        config.unlink()
        self.assertEqual(hook(tool_name="send_message", args={})["action"], "block")

    def test_a_bot_made_private_is_not_read_by_its_old_hook(self):
        hook = self.register()[3][1]
        load("private_bots").save(self.home, ["career"])
        # There is no config to read. An attempt would fail closed instead of skipping this bot.
        self.assertIsNone(hook(tool_name="send_message", args={}))

    def test_a_failed_rule_also_respects_an_explicit_off_choice(self):
        bot_home = self.home / "profiles" / "career"
        bot_home.mkdir(parents=True)
        (bot_home / "config.yaml").write_text(json.dumps({"plugins": {"enabled": []}}))
        with patch.object(load("ask_first"), "AskFirst", side_effect=RuntimeError("broken")), \
                self.assertLogs("nollie-workflow", "WARNING"):
            hook = self.register()[-1][1]
        self.assertIsNone(hook(tool_name="send_message", args={}))

    def test_main_and_new_helpers_ask_for_the_same_actions(self):
        rules = load("ask_first")
        calls = (("send_message", {"message": "Hello"}, "send"),
                 ("mcp__shop__buy", {"item": "Notebook"}, "buy"),
                 ("terminal", {"command": "git push"}, "post"),
                 ("terminal", {"command": "rm old.txt"}, "delete"))
        with patch.object(rules, "hermes_unattended", return_value=lambda: False), \
                patch.object(rules, "hermes_bypassed", return_value=False):
            for profile in ("default", "career", "new-helper"):
                hook = self.ask_first(self.register(profile)).hook
                for tool, args, kind in calls:
                    answer = hook(tool_name=tool, args=args)
                    self.assertEqual(answer["action"], "approve", (profile, tool))
                    self.assertTrue(answer["rule_key"].startswith(f"nollie-ask-first:{kind}:"), (profile, tool))
                self.assertIsNone(hook(tool_name="web_search", args={"query": "notebooks"}))

    def test_a_damaged_private_list_refuses_risky_calls_but_never_touches_the_always_private(self):
        (self.home / "nollie-private-bots.json").write_text("{")
        for profile in ("private", "moss", ""):
            self.assertEqual(self.register(profile), [], profile)
        for profile in ("career", "nowhere", "default"):
            self.assertEqual(self.register(profile), [("pre_tool_call", self.package._refuse_unguarded)], profile)
        refuse = self.register("nowhere")[0][1]
        answer = refuse(tool_name="terminal", args={"command": "rm -rf build"})
        self.assertEqual(answer["action"], "block")
        self.assertIn("safety check didn't start", answer["message"])
        self.assertIsNone(refuse(tool_name="web_search", args={"query": "ssd prices"}))

    def assert_refuses_what_it_would_check(self, hooks):
        # The picture pause may already be in; Ask first and its memory are not, and the stand-in is last.
        self.assertEqual((hooks[-1][0], inspect.unwrap(hooks[-1][1])),
                         ("pre_tool_call", self.package._refuse_unguarded))
        self.assertEqual([type(getattr(fn, "__self__", None)).__name__ for _, fn in hooks
                          if type(getattr(fn, "__self__", None)).__name__ in ("AskFirst", "Memory")], [])
        self.assertLessEqual(len(hooks), 4)
        refuse = hooks[-1][1]
        for tool, args in (("computer_use", {"action": "capture"}), ("mcp__cua__computer_click", {"x": 1, "y": 2}),
                           ("terminal", {"command": "rm -rf build"}), ("send_message", {"message": "hi"})):
            answer = refuse(tool_name=tool, args=args)
            self.assertEqual(answer["action"], "block", tool)
            self.assertIn("safety check didn't start", answer["message"])
        for tool, args in (("web_search", {"query": "ssd prices"}), ("read_file", {"path": "/tmp/a"}),
                           ("terminal", {"command": "ls"})):
            self.assertIsNone(refuse(tool_name=tool, args=args), tool)

    def test_if_ask_first_cant_start_risky_calls_are_refused(self):
        with patch.object(load("ask_first"), "AskFirst", side_effect=RuntimeError("broken")), \
                self.assertLogs("nollie-workflow", "WARNING") as logged:
            hooks = self.register()
        self.assertIn("Ask first did not start: RuntimeError", logged.output[0])
        self.assert_refuses_what_it_would_check(hooks)

    def test_if_its_import_fails_risky_calls_are_refused(self):
        with patch.dict(sys.modules, {NAME + ".screen_text": None}), self.assertLogs("nollie-workflow", "WARNING"):
            hooks = self.register()
        self.assert_refuses_what_it_would_check(hooks)
        with patch.dict(sys.modules, {NAME + ".ask_first": None}), self.assertLogs("nollie-workflow", "WARNING"):
            hooks = self.register()
        self.assert_refuses_what_it_would_check(hooks)

    def test_the_stand_in_fails_closed_when_it_cant_tell(self):
        with patch.object(load("sign_ins"), "shows_a_computer", side_effect=RuntimeError("odd")):
            for tool in ("mcp__cua__computer_click", "terminal", "send_message"):
                self.assertEqual(self.package._refuse_unguarded(tool_name=tool, args={})["action"], "block")
            # Looking things up still works.
            self.assertIsNone(self.package._refuse_unguarded(tool_name="web_search", args={}))

    def test_ask_first_never_looks_while_a_sign_in_is_typed(self):
        captured = []
        with patch.object(load("screen_text"), "capture_space", side_effect=lambda sandbox: captured.append(sandbox)):
            hooks = self.register()
        rule = self.ask_first(hooks)
        request = self.filling()
        self.assertIsNone(rule.screen.capture("local:dev"))
        self.assertEqual(captured, [])
        # Held as a click Nollie can't read, so it asks rather than looks. Without Hermes here nobody can
        # answer, so the hold is a block.
        answer = rule.hook(tool_name="mcp__cua__computer_click", args={"sandbox": "local:dev", "x": 5, "y": 5},
                           task_id="t", session_id="s")
        self.assertEqual(captured, [])
        self.assertEqual(answer["action"], "block")
        self.assertIn("Nollie couldn't read a label there", answer["message"])
        # The picture pause, registered first, refuses the same call outright.
        self.assertEqual(hooks[0][1](tool_name="mcp__cua__computer_click", args={})["action"], "block")
        request.unlink()
        rule.screen.capture("local:dev")
        self.assertEqual(captured, ["local:dev"])

    def test_a_picture_taken_as_a_fill_begins_is_thrown_away(self):
        def capture(sandbox):
            self.filling()  # The fill starts while the picture is being taken.
            return "a picture"
        with patch.object(load("screen_text"), "capture_space", side_effect=capture):
            rule = self.ask_first(self.register())
            self.assertIsNone(rule.screen.capture("local:dev"))
        with patch.object(load("screen_text"), "capture_space", return_value="a picture"):
            rule = self.ask_first(self.register())
            for path in (self.home / "nollie-workflow" / "sign-ins" / "requests").glob("*.json"):
                path.unlink()
            self.assertEqual(rule.screen.capture("local:dev"), "a picture")


class RecorderInstalledTests(unittest.TestCase):
    """The service's check that a bot's old heartbeat still means a recorder will load there."""

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.check = load("hermes_adapter").recorder_installed

    def config(self, text):
        (self.home / "config.yaml").write_text(text)

    def test_removed_disabled_or_left_out(self):
        self.assertFalse(self.check(self.home))
        folder = self.home / "plugins" / "nollie-workflow"
        folder.mkdir(parents=True)
        (folder / "recorder.py").write_text("")
        self.assertTrue(self.check(self.home))  # No config to say otherwise.
        self.config("plugins:\n  enabled: [nollie-workflow]\n")
        self.assertTrue(self.check(self.home))
        self.config("plugins:\n  enabled: [user/nollie-workflow]\n")
        self.assertTrue(self.check(self.home))
        self.config("plugins:\n  enabled: [nollie-workflow]\n  disabled: [nollie-workflow]\n")
        self.assertFalse(self.check(self.home))
        self.config("plugins:\n  enabled: [nollie-crew]\n")
        self.assertFalse(self.check(self.home))
        self.config("plugins: [\n")
        self.assertTrue(self.check(self.home))  # Unreadable says nothing either way.
        (folder / "recorder.py").unlink()
        self.assertFalse(self.check(self.home))

    def test_the_profile_named_private_is_always_excluded(self):
        excluded = load("private_bots").excluded
        self.assertTrue(excluded("private", frozenset({"moss"})))
        self.assertTrue(excluded("moss", frozenset({"moss"})))
        self.assertFalse(excluded("career", frozenset({"moss"})))
        self.assertEqual(load("private_bots").names(self.home), frozenset({"private", "moss"}))


class ControlTests(unittest.TestCase):
    def test_switches(self):
        with TemporaryDirectory() as temporary:
            home = Path(temporary)
            root = home / ".hermes/nollie-workflow"
            outputs = []
            for argv in (["night-shift", "on"], ["rehearsals", "on"], ["rehearsals", "off"]):
                with patch.object(Path, "home", return_value=home), patch("sys.argv", ["control.py", *argv]), \
                        patch("builtins.print", side_effect=outputs.append):
                    control.main()
            saved = json.loads((root / "night-shift.json").read_text())
            self.assertEqual((saved["night_shift"], saved["rehearsals"], saved["morning_hour"]), (True, False, 7))
            self.assertIsInstance(saved["rehearsals_since"], int)
            self.assertEqual(json.loads(outputs[-1]), {"night_shift": True, "rehearsals": False, "morning_hour": 7})
            with patch.object(Path, "home", return_value=home), patch("sys.argv", ["control.py", "rehearsals"]), \
                    patch("sys.stderr"), self.assertRaises(SystemExit):
                control.main()


if __name__ == "__main__":
    unittest.main()
