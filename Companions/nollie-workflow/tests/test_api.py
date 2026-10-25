import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

try:
    import fastapi
except ImportError:
    fastapi = None
try:
    from fastapi.testclient import TestClient
except (ImportError, RuntimeError):
    TestClient = None


@unittest.skipUnless(fastapi, "FastAPI is available in the Hermes runtime")
class APITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("workflow_api_test", Path(__file__).resolve().parents[1] / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)

    def test_attention_does_not_request_event_payloads(self):
        with patch.object(self.api, "home", return_value=Path("/fixture/default")), \
                patch.object(self.api._adapter, "BoardSource") as source:
            source.return_value.read.return_value = {"counts": {"default": 2, "work": 1}}
            response = self.api.attention()
            self.assertEqual(json.loads(response.body), {"counts": {"default": 2, "work": 1}})
            source.return_value.read.assert_called_once_with({}, 0, include_events=False)
            self.assertEqual(response.headers["cache-control"], "no-store")

    def test_endpoint_uses_installed_boundary_and_has_no_profile_input(self):
        with patch.object(self.api, "home", return_value=Path("/fixture/default")), \
                patch.object(self.api._core, "read_state", return_value={"installed_at": 123}), \
                patch.object(self.api._adapter, "BoardSource") as source:
            source.return_value.read.return_value = {"events": [], "cursors": {"default": {"task": 4}}}
            response = self.api.events(self.api.ReadEvents(cursors={"default": {"task": 3}}))
            source.return_value.read.assert_called_once_with({"default": {"task": 3}}, 123)
            self.assertEqual(json.loads(response.body)["events"], [])

    def test_nondefault_scope_refused_before_profile_home_access(self):
        profiles = SimpleNamespace(get_active_profile_name=lambda: "private",
                                   get_profile_dir=lambda p: self.fail("private scope resolved a home"))
        with patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles}):
            with self.assertRaises(fastapi.HTTPException) as raised:
                self.api.home()
        self.assertEqual(raised.exception.status_code, 403)

    def test_status_reports_loaded_capability_without_receipt_contents(self):
        with patch.object(self.api, "home", return_value=Path("/fixture/default")), \
                patch.object(self.api._core, "status", return_value={"enabled": False, "receipts": {"settled": 2}}), \
                patch.object(self.api, "watch_binding_ready", return_value=True):
            response = self.api.status()
            self.assertEqual(json.loads(response.body), {"enabled": False, "receipts": {"settled": 2},
                "plugin_version": "0.5.0", "watch_binding_ready": True})
            self.assertEqual(response.headers["cache-control"], "no-store")

    def test_unknown_native_capability_stays_unavailable(self):
        with patch.object(self.api._cron_followups, "ready", return_value=None):
            self.assertFalse(self.api.watch_binding_ready())



@unittest.skipUnless(fastapi and TestClient, "FastAPI and its test client are available in the Hermes runtime")
class PrivateBotsRouteTests(unittest.TestCase):
    PATH = "/api/plugins/nollie-workflow/private-bots"

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("workflow_api_private_test",
                                                      Path(__file__).resolve().parents[1] / "dashboard/plugin_api.py")
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
        profiles = SimpleNamespace(get_active_profile_name=lambda: self.active,
                                   get_profile_dir=lambda name: self.home if name == "default" else self.fail(name))
        modules = patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles})
        modules.start()
        self.addCleanup(modules.stop)

    def test_get_reports_the_carry_over_until_a_list_is_saved(self):
        response = self.client.get(self.PATH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"profiles": ["moss", "private"], "saved": False})
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertFalse((self.home / "nollie-private-bots.json").exists())

    def test_put_saves_the_list_and_get_reads_it_back(self):
        response = self.client.put(self.PATH, json={"profiles": ["Scout", "mason", "scout"]})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"profiles": ["mason", "scout"], "saved": True})
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(json.loads((self.home / "nollie-private-bots.json").read_text()),
                         {"version": 1, "profiles": ["mason", "scout"]})
        self.assertEqual(self.client.get(self.PATH).json(), {"profiles": ["mason", "scout"], "saved": True})
        self.assertEqual(self.client.put(self.PATH, json={"profiles": []}).json(), {"profiles": [], "saved": True})
        self.assertEqual(self.client.get(self.PATH).json(), {"profiles": [], "saved": True})

    def test_put_validates_names_and_count_without_writing(self):
        for body in ({"profiles": ["../moss"]}, {"profiles": ["two words"]}, {"profiles": [""]},
                     {"profiles": ["a" * 65]}, {"profiles": [f"bot{i}" for i in range(65)]},
                     {"profiles": "moss"}, {"profiles": [1]}, {}, {"profiles": None}):
            response = self.client.put(self.PATH, json=body)
            self.assertEqual(response.status_code, 422, body)
        self.assertFalse((self.home / "nollie-private-bots.json").exists())
        self.assertEqual(self.client.put(self.PATH, json={"profiles": [f"bot{i}" for i in range(64)]}).status_code, 200)

    def test_only_the_main_profile_reaches_the_list(self):
        self.active = "scout"
        self.assertEqual(self.client.get(self.PATH).status_code, 403)
        self.assertEqual(self.client.put(self.PATH, json={"profiles": []}).status_code, 403)
        self.assertFalse((self.home / "nollie-private-bots.json").exists())

    def test_damaged_list_is_unavailable_not_empty(self):
        (self.home / "nollie-private-bots.json").write_text("{")
        response = self.client.get(self.PATH)
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("profiles", response.json())
        # A whole new list repairs it.
        self.assertEqual(self.client.put(self.PATH, json={"profiles": ["moss"]}).status_code, 200)
        self.assertEqual(self.client.get(self.PATH).json(), {"profiles": ["moss"], "saved": True})

if __name__ == "__main__":
    unittest.main()
