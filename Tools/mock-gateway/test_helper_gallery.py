import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("helper_gallery_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

PLANNER = {"name": "Planner", "role": "plan your days and weeks",
           "come_to_me_for": "Bring me a busy week. I'll turn it into a plan.",
           "instructions": "Start with what matters most. Booking always waits for their yes.",
           "toolsets": ["todo", "memory"]}


class HelperGalleryMockTests(unittest.TestCase):
    def setUp(self):
        mock.profile_creation("POST", "/api/_mock/profile-creation", {})
        mock.CREW.update(undo={}, suggestions={}, members={})

    def roster(self):
        status, body = mock.crew_rest("GET", "/api/plugins/nollie-crew/crew", None)
        self.assertEqual(status, 200)
        return body

    def test_the_roster_opens_the_gallery(self):
        roster = self.roster()
        self.assertTrue(roster["ok"])
        self.assertEqual((roster["members"], roster["room"]), ([], mock.CREW_CAP))
        self.assertNotIn("private", roster["other_bots"])

    def test_a_ready_made_helper_is_added_with_its_words_and_undone(self):
        status, added = mock.crew_rest("POST", "/api/plugins/nollie-crew/members", dict(PLANNER))
        self.assertEqual(status, 200)
        self.assertEqual((added["status"], added["profile"], added["name"]), ("added", "planner", "Planner"))
        self.assertEqual(added["note"], "I've added Planner to plan your days and weeks.")
        profile = mock.CREATED_PROFILES["planner"]
        self.assertEqual((profile["display_name"], profile["description"]), ("Planner", PLANNER["come_to_me_for"]))
        _, soul = mock.rest("/api/profiles/planner/soul", {})
        self.assertIn(PLANNER["instructions"], soul["content"])
        self.assertEqual([m["profile"] for m in self.roster()["members"]], ["planner"])
        self.assertEqual(self.roster()["room"], mock.CREW_CAP - 1)

        self.assertEqual(mock.crew_rest("POST", "/api/plugins/nollie-crew/members", dict(PLANNER))[0], 409)
        status, undone = mock.crew_rest("POST", "/api/plugins/nollie-crew/undo", {"token": added["undo"]})
        self.assertEqual((status, undone["status"]), (200, "removed"))
        self.assertNotIn("planner", mock.CREATED_PROFILES)
        self.assertEqual(self.roster()["members"], [])
        self.assertEqual(mock.crew_rest("POST", "/api/plugins/nollie-crew/undo", {"token": added["undo"]})[0], 409)

    def test_refusals_match_the_add_on(self):
        for changes in ({"name": "Moss"}, {"name": "Private"}, {"name": "Work"},
                        {"instructions": "Buy it without asking."}):
            status, body = mock.crew_rest("POST", "/api/plugins/nollie-crew/members", dict(PLANNER, **changes))
            self.assertEqual(status, 409, changes)
            self.assertFalse(body["ok"])
        self.assertEqual(mock.crew_rest("POST", "/api/plugins/nollie-crew/members", {"name": "Planner"})[0], 422)
        self.assertEqual(mock.CREATED_PROFILES, {})

    def test_a_full_crew_is_refused(self):
        for index in range(mock.CREW_CAP):
            self.assertEqual(mock.crew_rest("POST", "/api/plugins/nollie-crew/members",
                                            dict(PLANNER, name=f"Helper {chr(65 + index)}"))[0], 200)
        status, body = mock.crew_rest("POST", "/api/plugins/nollie-crew/members", dict(PLANNER))
        self.assertEqual((status, body["status"]), (409, "full"))
        self.assertEqual(self.roster()["room"], 0)


if __name__ == "__main__":
    unittest.main()
