"""Keep skills as they are: the switch per helper, the hook that locks a skill the helper just made, and the routes
the Mac and the iPhone use. Private bots are refused and never get the hook."""
import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "keep_skills_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from keep_skills_test_package import keep_skills, private_bots  # noqa: E402

try:
    import fastapi
except ImportError:
    fastapi = None


class StoreTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.store = keep_skills.Store(self.home)

    def test_switches_round_trip(self):
        self.assertEqual(self.store.bots(), [])
        self.assertFalse(self.store.keeps("career"))
        self.store.set_bot("career", True)
        self.store.set_bot("nowhere", True)
        self.store.set_bot("career", True)
        self.assertEqual(self.store.bots(), ["career", "nowhere"])
        self.store.set_bot("nowhere", False)
        self.assertEqual(self.store.bots(), ["career"])
        self.assertTrue(self.store.keeps("career"))
        saved = json.loads((self.home / "nollie-workflow" / "keep-skills" / "bots.json").read_text())
        self.assertEqual(saved, {"version": 1, "bots": ["career"]})

    def test_on_must_be_true_or_false(self):
        with self.assertRaises(ValueError):
            self.store.set_bot("career", "yes")

    def test_a_damaged_file_reads_as_off_for_the_hook_and_raises_for_the_routes(self):
        folder = self.home / "nollie-workflow" / "keep-skills"
        folder.mkdir(parents=True)
        (folder / "bots.json").write_text("{")
        with self.assertRaises(ValueError):
            self.store.bots()
        self.assertFalse(self.store.keeps("career"))
        (folder / "bots.json").write_text(json.dumps({"version": 1, "bots": "career"}))
        with self.assertRaises(ValueError):
            self.store.bots()


class NewSkillLockTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.bot_home = self.home / "profiles" / "career"
        self.bot_home.mkdir(parents=True)
        self.store = keep_skills.Store(self.home)
        self.locked = []
        self.scope = self.bot_home

    def hook(self, lock=None):
        return keep_skills.NewSkillLock(self.store, "career", self.bot_home,
                                        lock=lock or (lambda name: self.locked.append(name) or True),
                                        home=lambda: self.scope)

    def test_a_new_skill_is_locked_while_the_switch_is_on(self):
        self.store.set_bot("career", True)
        hook = self.hook()
        hook(action="created", skill_name="weekly-prices", provenance="local")
        hook(action="installed", skill_name="hub-skill")
        self.assertEqual(self.locked, ["weekly-prices", "hub-skill"])

    def test_nothing_is_locked_with_the_switch_off(self):
        self.hook()(action="created", skill_name="weekly-prices")
        self.assertEqual(self.locked, [])

    def test_only_a_new_skill_counts(self):
        self.store.set_bot("career", True)
        hook = self.hook()
        for action in ("patched", "used", "viewed", "archived", None):
            hook(action=action, skill_name="weekly-prices")
        hook(action="created", skill_name="")
        hook(action="created", skill_name=None)
        self.assertEqual(self.locked, [])

    def test_never_in_another_helpers_home(self):
        self.store.set_bot("career", True)
        self.scope = self.home
        self.hook()(action="created", skill_name="weekly-prices")
        self.assertEqual(self.locked, [])

    def test_a_failed_lock_never_breaks_the_helper(self):
        self.store.set_bot("career", True)

        def broken(name):
            raise RuntimeError("sidecar not writable")
        with self.assertLogs("nollie-workflow", level="WARNING"):
            self.assertIsNone(self.hook(lock=broken)(action="created", skill_name="weekly-prices"))
        with self.assertLogs("nollie-workflow", level="WARNING"):
            self.hook(lock=lambda name: False)(action="created", skill_name="weekly-prices")

    def test_hermes_lock_uses_the_folder_name(self):
        calls = []
        usage = SimpleNamespace(set_locked=lambda key, on: calls.append((key, on)) or True)
        manager = SimpleNamespace(_find_skill=lambda name: {"path": Path("/skills/research/weekly-prices")}
                                  if name == "research/weekly-prices" else None)
        with patch.dict("sys.modules", {"tools": SimpleNamespace(skill_usage=usage), "tools.skill_usage": usage,
                                        "tools.skill_manager_tool": manager}):
            self.assertTrue(keep_skills.hermes_lock("research/weekly-prices"))
            self.assertFalse(keep_skills.hermes_lock("missing"))
        self.assertEqual(calls, [("weekly-prices", True)])


class RegisterTests(unittest.TestCase):
    """The hook loads for every helper that is not private, and never for a private one."""

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def registered(self, profile):
        hooks = []
        ctx = SimpleNamespace(register_hook=lambda name, hook: hooks.append(name))
        package._register_keep_skills(ctx, profile, self.home)
        return hooks

    def test_public_helpers_get_the_hook(self):
        self.assertEqual(self.registered("career"), ["on_skill_lifecycle"])
        self.assertEqual(self.registered("default"), ["on_skill_lifecycle"])

    def test_private_helpers_never_do(self):
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.registered("career"), [])
        self.assertEqual(self.registered("moss"), [])
        self.assertEqual(self.registered(""), [])


@unittest.skipUnless(fastapi, "FastAPI is available in the Hermes runtime")
class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        route_spec = importlib.util.spec_from_file_location("keep_skills_api_test", ROOT / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(route_spec)
        route_spec.loader.exec_module(cls.api)

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        for name, value in (("home", self.home), ("bot_home", self.home)):
            patcher = patch.object(self.api, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def body(self, response):
        self.assertEqual(response.headers["cache-control"], "no-store")
        return json.loads(response.body)

    def status(self, call, *args):
        with self.assertRaises(fastapi.HTTPException) as raised:
            call(*args)
        return raised.exception.status_code

    def test_the_switch_round_trips(self):
        self.assertEqual(self.body(self.api.keep_skills("career")), {"bot": "career", "on": False})
        on = self.api.save_keep_skills(self.api.KeepSkillsSwitch(bot="career", on=True))
        self.assertEqual(self.body(on), {"bot": "career", "on": True})
        self.assertEqual(self.body(self.api.keep_skills("career")), {"bot": "career", "on": True})
        off = self.api.save_keep_skills(self.api.KeepSkillsSwitch(bot="career", on=False))
        self.assertEqual(self.body(off), {"bot": "career", "on": False})

    def test_names_are_checked(self):
        self.assertEqual(self.status(self.api.keep_skills, "../etc"), 422)
        self.assertEqual(self.status(self.api.keep_skills, "two words"), 422)

    def test_private_bots_are_refused(self):
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.status(self.api.keep_skills, "career"), 403)
        self.assertEqual(self.status(self.api.keep_skills, "moss"), 403)
        self.assertEqual(self.status(self.api.save_keep_skills, self.api.KeepSkillsSwitch(bot="moss", on=True)), 403)
        self.assertFalse((self.home / "nollie-workflow" / "keep-skills" / "bots.json").exists())

    def test_a_damaged_switch_file_is_unavailable(self):
        folder = self.home / "nollie-workflow" / "keep-skills"
        folder.mkdir(parents=True)
        (folder / "bots.json").write_text("{")
        self.assertEqual(self.status(self.api.keep_skills, "career"), 503)


if __name__ == "__main__":
    unittest.main()
