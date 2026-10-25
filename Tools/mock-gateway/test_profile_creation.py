import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("profile_creation_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class ProfileCreationFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.profile_creation("POST", "/api/_mock/profile-creation", {})

    def test_explicit_route_is_saved_and_read_back_for_only_new_profile(self):
        body = {"name": "demo-research", "provider": "local", "model": "local/assistant"}
        status, acknowledgement = mock.profile_creation("POST", "/api/profiles", body)
        self.assertEqual(status, 200)
        self.assertTrue(acknowledgement["model_set"])
        _, options = mock.rest("/api/model/options", {"profile": body["name"]})
        self.assertEqual((options["provider"], options["model"]), ("local", "local/assistant"))
        self.assertEqual(mock.rest("/api/model/options", {"profile": "default"})[1]["model"], mock.MODEL)
        self.assertEqual([request["operation"] for request in mock.PROFILE_CREATION_LOG], ["create", "read_model"])

    def test_partial_model_failure_preserves_profile_and_repairs_without_creation(self):
        mock.profile_creation("POST", "/api/_mock/profile-creation", {"model_set_failure": True})
        body = {"name": "demo-retry", "provider": "local", "model": "local/assistant"}
        _, acknowledgement = mock.profile_creation("POST", "/api/profiles", body)
        self.assertFalse(acknowledgement["model_set"])
        self.assertEqual(mock.CREATED_PROFILES[body["name"]]["model"], "")
        self.assertEqual(mock.profile_creation("POST", "/api/profiles", body)[0], 409)
        self.assertEqual(mock.profile_creation("PUT", "/api/profiles/demo-retry/model", body)[0], 200)
        self.assertEqual(mock.CREATED_PROFILES[body["name"]]["model"], body["model"])
        self.assertEqual([request["operation"] for request in mock.PROFILE_CREATION_LOG], ["create", "set_model"])

    def test_control_reset_preserves_original_profiles_and_rejects_their_mutation(self):
        self.assertEqual(mock.profile_creation("PUT", "/api/profiles/default/model", {"provider": "local", "model": "a"})[0], 404)
        mock.profile_creation("POST", "/api/profiles", {"name": "demo-copy", "clone_from": "work"})
        self.assertEqual(mock.CREATED_PROFILES["demo-copy"]["model"], mock.MODEL)
        mock.profile_creation("POST", "/api/_mock/profile-creation", {})
        self.assertEqual(mock.CREATED_PROFILES, {})
        self.assertEqual(mock.PROFILES, ["default", "work"])


if __name__ == "__main__":
    unittest.main()
