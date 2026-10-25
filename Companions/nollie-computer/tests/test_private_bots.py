import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("computer_private_bots", ROOT / "dashboard/private_bots.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

WORKFLOW = ROOT.parent / "nollie-workflow"
workflow = None
if (WORKFLOW / "private_bots.py").is_file():
    NAME = "computer_parity_workflow"
    spec = importlib.util.spec_from_file_location(NAME, WORKFLOW / "__init__.py", submodule_search_locations=[str(WORKFLOW)])
    sys.modules[NAME] = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sys.modules[NAME])
    workflow = __import__(NAME + ".private_bots", fromlist=["read"])

FIXTURES = [
    None,
    {"version": 1, "profiles": []},
    {"version": 1, "profiles": ["moss", "scout", "work_2", "0"]},
    {"version": 1, "profiles": ["Moss"]},
    {"version": 1, "profiles": ["../x"]},
    {"version": 1, "profiles": "moss"},
    {"version": 1, "profiles": [f"bot{i}" for i in range(65)]},
    {"version": 2, "profiles": []},
    {"version": 1},
    [],
    "{",
]


def answer(module, home):
    try:
        return module.read(home)
    except ValueError:
        return "refused"


class ReaderTests(unittest.TestCase):
    def write(self, home, fixture):
        path = Path(home) / "nollie-private-bots.json"
        if fixture is not None:
            path.write_text(fixture if isinstance(fixture, str) else json.dumps(fixture))

    def test_reader_answers(self):
        expected = [(frozenset({"private", "moss"}), False), (frozenset(), True),
                    (frozenset({"moss", "scout", "work_2", "0"}), True)] + ["refused"] * 8
        for fixture, result in zip(FIXTURES, expected):
            with TemporaryDirectory() as home:
                self.write(home, fixture)
                self.assertEqual(answer(reader, home), result, fixture)

    @unittest.skipUnless(workflow, "nollie-workflow sits beside this companion in the repository")
    def test_reader_matches_the_workflow_copy(self):
        self.assertEqual(reader.FILE_NAME, workflow.FILE_NAME)
        self.assertEqual(reader.carried_over_names(), workflow.carried_over_names())
        for fixture in FIXTURES:
            with TemporaryDirectory() as home:
                self.write(home, fixture)
                self.assertEqual(answer(reader, home), answer(workflow, home), fixture)
        with TemporaryDirectory() as home:
            workflow.save(home, ["Scout", "mason"])
            self.assertEqual(reader.read(home), (frozenset({"scout", "mason"}), True))


if __name__ == "__main__":
    unittest.main()
