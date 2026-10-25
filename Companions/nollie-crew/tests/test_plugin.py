import importlib
import json
import unittest
from unittest.mock import patch

from support import PACKAGE, Home, tools_module

try:
    import fastapi
    from fastapi.testclient import TestClient
except ImportError:
    fastapi = None


class FakeContext:
    def __init__(self, profile):
        self.profile_name = profile
        self.tools, self.hooks = {}, {}

    def register_tool(self, name, toolset, schema, handler, description=""):
        self.tools[name] = (toolset, schema, handler)

    def register_hook(self, name, callback):
        self.hooks[name] = callback


class RegistrationTests(unittest.TestCase):
    def test_other_profiles_get_no_tools(self):
        plugin = importlib.import_module(PACKAGE)
        for profile in ("career", "private", "custom"):
            ctx = FakeContext(profile)
            plugin.register(ctx)
            self.assertEqual((ctx.tools, ctx.hooks), ({}, {}))

    def test_tools_and_hooks_register_with_schemas(self):
        home = Home()
        self.addCleanup(home.cleanup)
        ctx = FakeContext("default")
        home.tools.register(ctx)
        self.assertEqual(set(ctx.tools), {"crew_add", "crew_list", "crew_update", "crew_pause", "crew_resume",
                                          "crew_retire", "crew_undo", "crew_not_now"})
        self.assertEqual(set(ctx.hooks), {"pre_tool_call", "post_approval_response"})
        for name, (toolset, schema, handler) in ctx.tools.items():
            self.assertEqual(toolset, "nollie_crew")
            self.assertEqual(schema["name"], name)
            self.assertEqual(schema["parameters"]["type"], "object")
            self.assertNotIn(chr(0x2014), schema["description"])
        result = json.loads(ctx.tools["crew_list"][2]({}, task_id="t", session_id="s"))
        self.assertTrue(result["ok"])

    def test_manifest_lists_every_tool(self):
        from support import ROOT
        text = (ROOT / "plugin.yaml").read_text()
        for name in tools_module.SCHEMAS:
            self.assertIn(name, text)


@unittest.skipUnless(fastapi and importlib.util.find_spec("hermes_cli"), "FastAPI and Hermes's source are available (the Hermes runtime)")
class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)
        import importlib.util
        from pathlib import Path
        spec = importlib.util.spec_from_file_location("crew_dashboard_test", Path(__file__).resolve().parents[1] / "dashboard/plugin_api.py")
        self.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.api)
        app = fastapi.FastAPI()
        app.include_router(self.api.router)
        self.client = TestClient(app)

    def test_suggestion_tap_and_undo(self):
        idea = {"name": "Rover", "role": "watch app reviews", "come_to_me_for": "App reviews.", "asked_by_person": False}
        key = self.home.call("crew_add", idea)["suggestion"]
        with patch.object(self.api, "crew", return_value=self.home.crew):
            self.assertEqual(self.client.post(f"/suggestions/{key}", json={"answer": "maybe"}).status_code, 400)
            added = self.client.post(f"/suggestions/{key}", json={"answer": "add"})
            self.assertEqual(added.status_code, 200)
            self.assertEqual(added.headers["cache-control"], "no-store")
            self.assertEqual(self.client.post(f"/suggestions/{key}", json={"answer": "add"}).status_code, 409)
            listed = self.client.get("/crew").json()
            self.assertEqual([m["name"] for m in listed["members"]], ["Rover"])
            undone = self.client.post("/undo", json={"token": added.json()["undo"]})
            self.assertEqual(undone.json()["status"], "removed")

    def test_other_profiles_are_refused(self):
        with patch("hermes_cli.profiles.get_active_profile_name", return_value="career"):
            self.assertEqual(self.client.get("/crew").status_code, 403)


if __name__ == "__main__":
    unittest.main()
