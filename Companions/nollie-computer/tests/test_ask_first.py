import asyncio
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


core = load("ask_first_for_test", ROOT / "dashboard/ask_first.py")


class AskFirstTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.root = Path(self.temp.name) / "home"
        self.bot = self.root / "profiles" / "work"
        self.bot.mkdir(parents=True)
        self.document = {"plugins": {"enabled": ["other", "nollie-workflow"], "disabled": ["paused"],
                                      "entries": {"other": {"setting": "keep"}}},
                         "model": "fixture", "terminal": {"backend": "local"}}
        for home in (self.root, self.bot):
            (home / "config.yaml").write_text(json.dumps(self.document))
        self.private = {"private", "moss", "diary"}
        self.homes = Mock(side_effect=lambda profile: self.root if profile == "default" else self.root / "profiles" / profile)
        self.refresh = Mock()
        self.service = core.AskFirst(lambda: self.root, lambda: self.private, self.homes, self.refresh)

    def tearDown(self):
        self.temp.cleanup()

    def test_turn_off_and_on_keep_the_add_on_and_other_settings(self):
        original_default = (self.root / "config.yaml").read_bytes()
        original_bot = (self.bot / "config.yaml").read_bytes()
        self.assertEqual(self.service.status("work"), {"profile": "work", "enabled": True})
        self.assertEqual(self.service.change("work", False), {"profile": "work", "enabled": False})
        # The add-on stays on, so sending, buying, posting and deleting still ask; only the switch file changes.
        self.assertEqual((self.bot / "config.yaml").read_bytes(), original_bot)
        self.assertEqual((self.root / "config.yaml").read_bytes(), original_default)
        switch = self.bot / "nollie-workflow" / core.SWITCH
        self.assertEqual(json.loads(switch.read_text()), {"version": 1, "enabled": False})
        self.assertEqual(switch.stat().st_mode & 0o777, 0o600)
        marker = self.bot / "nollie-workflow" / core.MARKER
        self.assertEqual(marker.read_text(), "1\n")
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.service.change("work", True)["enabled"])
        self.assertEqual(json.loads(switch.read_text()), {"version": 1, "enabled": True})
        self.assertEqual(json.loads((self.bot / "config.yaml").read_text()), self.document)
        # The running rule reads the switch before each call: nothing to reload.
        self.refresh.assert_not_called()

    def test_removed_enabled_and_disabled_alias_both_show_off(self):
        for plugins in ({"enabled": ["other"]},
                        {"enabled": ["nollie-workflow"], "disabled": ["custom/nollie-workflow"]}):
            (self.bot / "config.yaml").write_text(json.dumps({"plugins": plugins}))
            self.assertFalse(self.service.status("work")["enabled"])
        self.assertTrue(self.service.change("work", True)["enabled"])
        self.assertEqual(json.loads((self.bot / "config.yaml").read_text())["plugins"]["disabled"], [])
        self.refresh.assert_called_once_with("work", self.bot, True)

    def test_turning_off_an_add_on_an_older_nollie_switched_off_turns_it_back_on(self):
        (self.bot / "config.yaml").write_text(json.dumps({"plugins": {"enabled": ["other"],
                                                                      "disabled": ["nollie-workflow"]}}))
        self.assertEqual(self.service.change("work", False), {"profile": "work", "enabled": False})
        plugins = json.loads((self.bot / "config.yaml").read_text())["plugins"]
        self.assertEqual((plugins["enabled"], plugins["disabled"]), (["other", "nollie-workflow"], []))
        self.refresh.assert_called_once_with("work", self.bot, True)

    def test_a_damaged_or_linked_switch_is_left_alone(self):
        state = self.bot / "nollie-workflow"
        state.mkdir()
        switch = state / core.SWITCH
        for text in ("{", '{"version": 1, "enabled": "no"}', "[]"):
            switch.write_text(text)
            with self.assertRaises(core.Refused):
                self.service.status("work")
            with self.assertRaises(core.Refused):
                self.service.change("work", False)
            self.assertEqual(switch.read_text(), text)
        switch.unlink()
        switch.symlink_to(self.root / "config.yaml")
        with self.assertRaises(core.Refused):
            self.service.change("work", False)
        self.assertTrue(switch.is_symlink())

    def test_main_bot_can_turn_ask_first_back_on_while_workflow_is_disabled(self):
        config = self.root / "config.yaml"
        config.write_text(json.dumps({"plugins": {"enabled": ["nollie-computer"],
                                                  "disabled": ["nollie-workflow"]}}))
        before = config.read_bytes()
        self.assertFalse(self.service.status("default")["enabled"])
        self.assertEqual(config.read_bytes(), before)
        self.assertFalse((self.root / "nollie-workflow").exists())
        self.assertTrue(self.service.change("default", True)["enabled"])
        self.refresh.assert_called_once_with("default", self.root, True)
        self.assertEqual(json.loads(config.read_text())["plugins"]["enabled"],
                         ["nollie-computer", "nollie-workflow"])

    def test_repeating_a_choice_marks_it_without_rewriting_config(self):
        before = (self.bot / "config.yaml").stat().st_ino
        self.service.change("work", True)
        self.assertEqual((self.bot / "config.yaml").stat().st_ino, before)
        self.assertEqual((self.bot / "nollie-workflow" / core.MARKER).read_text(), "1\n")

    def test_private_bots_are_rejected_before_lookup_or_creation(self):
        for name in ("private", "moss", "diary", "private-notes", "moss_notes", "diary-notes"):
            for action in (lambda: self.service.status(name), lambda: self.service.change(name, False)):
                with self.assertRaises(core.Refused) as error:
                    action()
                self.assertEqual(error.exception.status, 403)
        self.homes.assert_not_called()
        self.refresh.assert_not_called()
        self.assertEqual(sorted(path.name for path in (self.root / "profiles").iterdir()), ["work"])
        self.private.clear()
        with self.assertRaises(core.Refused):
            self.service.change("moss", True)
        self.homes.assert_not_called()

    def test_invalid_names_and_bad_privacy_never_look_up_a_bot(self):
        for name in ("../work", "work/other", "", "WORK", "a" * 65):
            with self.assertRaises(core.Refused) as error:
                self.service.status(name)
            self.assertEqual(error.exception.status, 422)
        self.service.private_reader = Mock(side_effect=ValueError())
        with self.assertRaises(core.Refused) as error:
            self.service.change("work", True)
        self.assertEqual(error.exception.status, 503)
        self.homes.assert_not_called()

    def test_malformed_config_is_not_replaced_or_marked(self):
        config = self.bot / "config.yaml"
        for content in ('[]', '{"plugins": []}', '{"plugins": {"enabled": "nollie-workflow"}}'):
            config.write_text(content)
            with self.assertRaises(core.Refused):
                self.service.change("work", False)
            self.assertEqual(config.read_text(), content)
            self.assertFalse((self.bot / "nollie-workflow" / core.MARKER).exists())
        self.refresh.assert_not_called()

    def test_linked_config_or_marker_and_invalid_marker_are_left_alone(self):
        config = self.bot / "config.yaml"
        original = config.read_bytes()
        config.unlink()
        config.symlink_to(self.root / "config.yaml")
        with self.assertRaises(core.Refused):
            self.service.change("work", False)
        self.assertEqual((self.root / "config.yaml").read_bytes(), original)
        config.unlink()
        config.write_bytes(original)
        state = self.bot / "nollie-workflow"
        state.mkdir()
        marker = state / core.MARKER
        marker.symlink_to(self.root / "config.yaml")
        with self.assertRaises(core.Refused):
            self.service.change("work", False)
        marker.unlink()
        marker.write_text("damaged")
        with self.assertRaises(core.Refused):
            self.service.change("work", False)
        self.assertEqual(config.read_bytes(), original)
        self.assertEqual(marker.read_text(), "damaged")

    def test_body_value_must_be_a_boolean(self):
        for value in (None, 0, 1, "false", [], {}):
            with self.assertRaises(core.Refused) as error:
                self.service.change("work", value)
            self.assertEqual(error.exception.status, 422)
        self.homes.assert_not_called()

    def test_failed_activation_reports_saved_state_without_undoing_the_choice(self):
        (self.bot / "config.yaml").write_text(json.dumps({"plugins": {"disabled": ["nollie-workflow"]}}))
        self.refresh.side_effect = RuntimeError("fixture")
        with self.assertRaises(core.Refused) as error:
            self.service.change("work", True)
        self.assertEqual(error.exception.status, 503)
        self.assertTrue(self.service.status("work")["enabled"])
        self.assertTrue((self.bot / "nollie-workflow" / core.MARKER).exists())

    def test_a_second_choice_waits_until_the_first_has_refreshed(self):
        refreshing, release, second_waiting, second_done = (threading.Event() for _ in range(4))
        results, errors = {}, []
        original_lock = core.fcntl.flock
        def observed_lock(descriptor, operation):
            if threading.current_thread().name == "second-choice":
                second_waiting.set()
            original_lock(descriptor, operation)
        def refresh(profile, home, enabled):
            if threading.current_thread().name != "second-choice":
                refreshing.set()
                if not release.wait(2):
                    raise RuntimeError("fixture timed out")
        def change(name, enabled):
            try:
                results[name] = self.service.change("work", enabled)
            except Exception as error:
                errors.append(error)
            finally:
                if enabled:
                    second_done.set()
        self.service.refresh = refresh
        (self.bot / "config.yaml").write_text(json.dumps({"plugins": {"disabled": ["nollie-workflow"]}}))
        first = threading.Thread(target=change, args=("first", False))
        second = threading.Thread(target=change, args=("second", True), name="second-choice")
        with patch.object(core.fcntl, "flock", observed_lock):
            first.start()
            try:
                self.assertTrue(refreshing.wait(2))
                second.start()
                self.assertTrue(second_waiting.wait(2))
                self.assertFalse(second_done.wait(0.05))
            finally:
                release.set()
                first.join(2)
                if second.ident is not None:
                    second.join(2)
        self.assertEqual(errors, [])
        self.assertEqual(results["first"], {"profile": "work", "enabled": False})
        self.assertEqual(results["second"], {"profile": "work", "enabled": True})


class ActivationTests(unittest.TestCase):
    def test_unknown_profile_is_rejected_before_resolving_its_home(self):
        resolve = Mock()
        modules = {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": SimpleNamespace(
            get_profile_dir=resolve, profile_exists=lambda profile: False)}
        with patch.dict(sys.modules, modules), self.assertRaises(core.Refused) as error:
            core.profile_home("missing")
        self.assertEqual(error.exception.status, 404)
        resolve.assert_not_called()

    def test_refresh_uses_the_named_profile_and_requires_evidence_for_on(self):
        home = Path("/fixture/home/profiles/work")
        scopes = []
        @contextmanager
        def scope(profile):
            scopes.append(profile)
            yield
        activate = Mock(return_value={"gateway_reloaded": True,
                                      "activation": {"activated_now": {"hooks": ["pre_tool_call"]}}})
        modules = {"hermes_cli": SimpleNamespace(),
                   "hermes_cli.plugins_activation": SimpleNamespace(activate_plugin_now=activate),
                   "hermes_cli.web_server_profiles": SimpleNamespace(_config_profile_scope=scope),
                   "hermes_constants": SimpleNamespace(get_hermes_home=lambda: home)}
        with patch.dict(sys.modules, modules):
            core.refresh_plugin("work", home, True)
            self.assertEqual(scopes, ["work"])
            activate.assert_called_once_with("nollie-workflow")
            activate.return_value = {"activation": None, "gateway_reloaded": False}
            with self.assertRaises(core.Refused):
                core.refresh_plugin("work", home, True)
            activate.return_value = {"activation": None, "gateway_reloaded": True}
            with self.assertRaises(core.Refused):
                core.refresh_plugin("work", home, True)
            activate.return_value = {"activation": {"activated_now": {"hooks": ["post_tool_call"]}}}
            with self.assertRaises(core.Refused):
                core.refresh_plugin("work", home, True)
            activate.return_value = {"gateway_reloaded": False,
                                      "activation": {"activated_now": {"hooks": ["pre_tool_call"]}}}
            with self.assertRaises(core.Refused):
                core.refresh_plugin("work", home, True)
            core.refresh_plugin("work", home, False)
            activate.reset_mock()
            with self.assertRaises(core.Refused):
                core.refresh_plugin("work", Path("/fixture/home"), True)
            activate.assert_not_called()


class RouteTests(unittest.TestCase):
    def test_http_validation_and_profile_targeting(self):
        try:
            from fastapi import FastAPI
            from fastapi.testclient import TestClient
        except ImportError:
            self.skipTest("fastapi is not installed")
        api = load("computer_ask_first_http", ROOT / "dashboard/plugin_api.py")
        service = Mock()
        service.status.return_value = {"profile": "work", "enabled": True}
        service.change.return_value = {"profile": "work", "enabled": False}
        api._ask_first_service = service
        app = FastAPI()
        app.include_router(api.router)
        client = TestClient(app)
        self.assertEqual(client.get("/ask-first", params={"profile": "work"}).json(), service.status.return_value)
        service.status.assert_called_once_with("work")
        for body in ({}, {"enabled": "false"}, {"enabled": 0}, {"enabled": False, "profile": "default"}):
            self.assertEqual(client.put("/ask-first", params={"profile": "work"}, json=body).status_code, 422)
        self.assertEqual(client.get("/ask-first").status_code, 422)
        self.assertEqual(client.get("/ask-first", params={"profile": "a" * 65}).status_code, 422)
        service.change.assert_not_called()
        response = client.put("/ask-first", params={"profile": "work"}, json={"enabled": False})
        self.assertEqual(response.json(), {"profile": "work", "enabled": False})
        self.assertEqual(response.headers["cache-control"], "no-store")
        service.change.assert_called_once_with("work", False)

    def test_route_dispatch_and_refusals_without_a_running_gateway(self):
        class Router:
            def __init__(self, **_):
                self.routes = {}
            def route(self, method, path):
                def register(function):
                    self.routes[method, path] = function
                    return function
                return register
            def get(self, path): return self.route("GET", path)
            def put(self, path): return self.route("PUT", path)
            def post(self, path): return self.route("POST", path)
        class Response:
            def __init__(self, body, status_code=200, headers=None):
                self.body, self.status_code, self.headers = body, status_code, headers
        modules = {"fastapi": SimpleNamespace(APIRouter=Router, Body=lambda *a, **k: None, Query=lambda *a, **k: None),
                   "fastapi.responses": SimpleNamespace(JSONResponse=Response),
                   "pydantic": SimpleNamespace(BaseModel=object, StrictBool=bool)}
        with patch.dict(sys.modules, modules):
            api = load("computer_ask_first_routes", ROOT / "dashboard/plugin_api.py")
        service = Mock()
        service.status.return_value = {"profile": "work", "enabled": False}
        service.change.return_value = {"profile": "work", "enabled": True}
        api._ask_first_service = service
        read = asyncio.run(api.router.routes["GET", "/ask-first"]("work"))
        self.assertEqual(read.body, {"profile": "work", "enabled": False})
        self.assertEqual(read.headers["Cache-Control"], "no-store")
        change = asyncio.run(api.router.routes["PUT", "/ask-first"](SimpleNamespace(enabled=True), "work"))
        self.assertEqual(change.body, {"profile": "work", "enabled": True})
        service.change.assert_called_once_with("work", True)
        service.status.side_effect = api._ask_first.Refused(403, "Ask first is not changed for private bots.")
        refused = asyncio.run(api.ask_first("diary"))
        self.assertEqual(refused.status_code, 403)
        self.assertEqual(refused.headers["Cache-Control"], "no-store")
        self.assertEqual(api.AskFirstChange.model_config, {"extra": "forbid"})


if __name__ == "__main__":
    unittest.main()
