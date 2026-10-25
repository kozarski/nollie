import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("private_bots_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

PATH = "/api/plugins/nollie-workflow/private-bots"


class PrivateBotsFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        self.request("/api/_mock/private-bots", "POST")
        mock.profile_creation("POST", "/api/_mock/profile-creation", {})
        self.original_boards = copy.deepcopy(mock.KANBAN_BOARDS)
        self.original_tasks = copy.deepcopy(mock.KANBAN_TASKS)

    def tearDown(self):
        self.request("/api/_mock/private-bots", "POST")
        mock.profile_creation("POST", "/api/_mock/profile-creation", {})
        mock.KANBAN_BOARDS[:] = self.original_boards
        mock.KANBAN_TASKS.clear()
        mock.KANBAN_TASKS.update(self.original_tasks)

    def request(self, path=PATH, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def test_carry_over_until_saved_then_only_the_list(self):
        self.assertEqual(self.request(), (200, {"profiles": ["moss", "private"], "saved": False}))
        self.assertEqual(self.request(method="PUT", body={"profiles": ["Work", "work", "scout"]}),
                         (200, {"profiles": ["scout", "work"], "saved": True}))
        self.assertEqual(self.request(), (200, {"profiles": ["scout", "work"], "saved": True}))
        self.assertEqual(self.request(method="PUT", body={"profiles": []}), (200, {"profiles": [], "saved": True}))
        self.assertEqual(self.request()[1], {"profiles": [], "saved": True})
        self.assertEqual(self.request("/api/_mock/private-bots", "POST")[1], {"profiles": ["moss", "private"], "saved": False})

    def test_put_validation_and_main_profile_only(self):
        for body in ({"profiles": ["../x"]}, {"profiles": ["two words"]}, {"profiles": [""]}, {"profiles": [1]},
                     {"profiles": "work"}, {}, {"profiles": [f"bot{i}" for i in range(65)]}):
            self.assertEqual(self.request(method="PUT", body=body)[0], 422, body)
        self.assertEqual(self.request()[1]["saved"], False)
        self.assertEqual(self.request(method="PUT", body={"profiles": [f"bot{i}" for i in range(64)]})[0], 200)
        self.assertEqual(self.request(PATH + "?profile=work")[0], 403)
        self.assertEqual(self.request(PATH + "?profile=work", "PUT", {"profiles": []})[0], 403)

    def test_board_attention_follows_every_bot_and_the_list(self):
        def task(tid, **fields):
            result = mock._ktask(tid, "Synthetic task " + tid, "blocked", "default")
            result.update(block_kind="needs_input", **fields)
            return result
        mock.profile_creation("POST", "/api/profiles", {"name": "scout"})
        mock.KANBAN_TASKS["default"] = [task("a"), task("b", assignee="work"), task("c", assignee="scout"),
                                        task("d", tenant="team:scout"), task("e", assignee="private")]
        mock.KANBAN_BOARDS.append({"slug": "private", "archived": False})
        mock.KANBAN_TASKS["private"] = [task("f")]
        attention = "/api/plugins/nollie-workflow/attention"
        # "private" is not a listed bot here, so its assignment never counts; its board is hidden by the carry-over.
        self.assertEqual(self.request(attention)[1]["counts"], {"default": 4, "homelab": 0})
        self.request(method="PUT", body={"profiles": ["scout"]})
        self.assertEqual(self.request(attention)[1]["counts"], {"default": 2, "homelab": 0, "private": 1})

    def test_computer_preview_refuses_private_profiles_from_the_list(self):
        sid = mock.COMPUTER_SESSION
        mock.COMPUTER_PREVIEW.update(state="live", requests=[])
        self.assertEqual(mock.computer_preview_rest({"profile": "default", "session_id": sid})[1]["state"], "live")
        self.request(method="PUT", body={"profiles": ["default"]})
        self.assertEqual(mock.computer_preview_rest({"profile": "default", "session_id": sid})[1],
                         {"state": "unavailable", "message": "This chat has no available computer preview."})
        self.assertEqual(mock.computer_preview_rest({"profile": "Default", "session_id": sid})[1]["state"], "unavailable")

    def test_profile_named_private_is_an_ordinary_profile(self):
        self.assertEqual(mock.profile_creation("POST", "/api/profiles", {"name": "private"})[0], 200)


if __name__ == "__main__":
    unittest.main()
