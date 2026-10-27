"""Ready-made helpers from a linked phone: the gallery's calls, the Nollie Link door's allowlist and this mock
agree. The door lets through exactly the roster, Add and Undo; a suggestion's Add (which can bring a
schedule) stays on the Mac."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("link_crew_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

PLANNER = {"name": "Planner", "role": "plan your days and weeks",
           "come_to_me_for": "Bring me a busy week. I'll turn it into a plan.",
           "instructions": "Start with what matters most. Booking always waits for their yes.",
           "toolsets": ["todo", "memory"]}


def door_crew_rules() -> set[tuple[str, str]]:
    """(method, path) pairs the door allows under the crew add-on, read from its policy."""
    source = (ROOT / "Services/Runtime/LinkDoorPolicy.swift").read_text()
    found = set()
    for methods, path in re.findall(r'Rule\(\[([^\]]*)\], "(/api/plugins/nollie-crew[^"]*)"', source):
        for method in re.findall(r'"([A-Z]+)"', methods):
            found.add((method, path))
    return found


def gallery_calls() -> set[tuple[str, str]]:
    """(method, path) pairs the app's gallery sends, read from its source."""
    source = (ROOT / "Apps/Nollie/Bots/HelperGallery.swift").read_text()
    base = re.search(r'crewPath = "([^"]+)"', source).group(1)
    calls = {("GET", base + tail) for tail in re.findall(r'api\.get\(crewPath \+ "([^"]+)"\)', source)}
    calls |= {(method, base + tail) for method, tail in re.findall(r'api\.send\("([A-Z]+)", crewPath \+ "([^"]+)"', source)}
    return calls


class LinkCrewRouteTests(unittest.TestCase):
    def setUp(self):
        mock.profile_creation("POST", "/api/_mock/profile-creation", {})
        mock.CREW.update(undo={}, suggestions={}, members={})

    def test_the_door_allows_exactly_what_the_gallery_sends(self):
        self.assertEqual(gallery_calls(), {("GET", "/api/plugins/nollie-crew/crew"),
                                           ("POST", "/api/plugins/nollie-crew/members"),
                                           ("POST", "/api/plugins/nollie-crew/undo")})
        self.assertEqual(door_crew_rules(), gallery_calls())

    def test_suggestions_stay_on_the_mac(self):
        self.assertFalse(any("suggestions" in path for _, path in door_crew_rules()))

    def test_the_mock_answers_every_allowed_route(self):
        status, roster = mock.crew_rest("GET", "/api/plugins/nollie-crew/crew", None)
        self.assertEqual((status, roster["ok"]), (200, True))
        status, added = mock.crew_rest("POST", "/api/plugins/nollie-crew/members", dict(PLANNER))
        self.assertEqual((status, added["status"]), (200, "added"))
        status, undone = mock.crew_rest("POST", "/api/plugins/nollie-crew/undo", {"token": added["undo"]})
        self.assertEqual((status, undone["status"]), (200, "removed"))


if __name__ == "__main__":
    unittest.main()
