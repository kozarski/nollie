"""Sharing a helper at home in the mock: the door's /nollie/family routes for the owner's phone and for
the phone of someone a helper was shared with, who sees only that helper and their own chats."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("family_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class FamilyFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        self.request("/api/_mock/family", "POST", {"reset": True})

    tearDown = setUp

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def test_the_owner_sees_people_and_their_asks(self):
        self.assertEqual(self.request("/nollie/family/me"), (200, {"role": "owner"}))
        status, body = self.request("/nollie/family")
        self.assertEqual(status, 200)
        self.assertEqual([m["person"] for m in body["members"]], ["Sam", "Mum"])
        ask = body["asks"][0]
        self.assertEqual((ask["person"], ask["helper"]), ("Sam", "work-sam"))
        self.assertTrue(ask["request"]["pattern_key"].startswith("plugin_rule:nollie-ask-first:send:"))

    def test_the_owner_answers_and_removes(self):
        status, body = self.request("/nollie/family/asks/srq-0123456789ab", "POST", {"choice": "always"})
        self.assertEqual(status, 400)
        status, body = self.request("/nollie/family/asks/srq-0123456789ab", "POST", {"choice": "once"})
        self.assertEqual((status, body["asks"]), (200, []))
        status, body = self.request("/nollie/family/members/6f9619ff-8b86-d011-b42d-00c04fc964ff", "DELETE")
        self.assertEqual([m["person"] for m in body["members"]], ["Mum"])
        log = self.request("/api/_mock/family")[1]["log"]
        self.assertEqual([entry["operation"] for entry in log], ["answer", "remove"])

    def test_an_invite_gives_a_version_two_codes_fields(self):
        self.request("/api/_mock/profile-creation", "POST", {})
        status, body = self.request("/nollie/family/invite", "POST", {"person": "Alex", "helpers": ["work"]})
        self.assertEqual(status, 200)
        self.assertEqual((body["owner"], body["helpers"], body["port"]), ("Corey", ["Work"], 52345))
        # The person's own copy, locked down, as the door makes it.
        copy = mock.CREATED_PROFILES["work-alex"]
        self.assertEqual(copy["clone_from"], "work")
        self.assertTrue({"terminal", "file", "code_execution", "computer_use", "browser", "connections"} <= set(copy["disabled_toolsets"]))
        self.assertFalse({"web", "search", "memory", "tts"} & set(copy["disabled_toolsets"]))
        self.request("/api/_mock/profile-creation", "POST", {})
        self.assertEqual(self.request("/nollie/family/invite", "POST", {"person": "Alex", "helpers": ["moss"]})[0], 403)
        self.assertEqual(self.request("/nollie/family/invite", "POST", {"person": "", "helpers": ["work"]})[0], 400)

    def test_a_member_sees_only_what_was_shared(self):
        self.request("/api/_mock/family", "POST", {"role": "member"})
        status, me = self.request("/nollie/family/me")
        self.assertEqual((status, me["role"], me["owner"], me["helpers"]), (200, "member", "Corey", ["work-sam"]))
        self.assertEqual([p["name"] for p in self.request("/api/profiles")[1]["profiles"]], ["work-sam"])
        status, chats = self.request("/api/sessions?profile=work-sam&limit=20")
        self.assertEqual(status, 200)
        self.assertTrue(all(row["profile"] == "work-sam" for row in chats["sessions"]))
        self.assertEqual(self.request("/api/sessions?profile=default")[0], 403)
        self.assertEqual(self.request("/nollie/family")[0], 403)
        self.assertEqual(self.request("/nollie/family/asks/srq-0123456789ab", "POST", {"choice": "once"})[0], 403)


if __name__ == "__main__":
    unittest.main()
