"""Ask first on ordinary work: reading, looking things up and tidying its own files raise few cards."""
import json
import os
from pathlib import Path
import unittest

from night_support import load

ask_first = load("ask_first")
CORPUS = json.loads((Path(__file__).with_name("fixtures") / "everyday.json").read_text())
CASES, CHANGES = CORPUS["cases"], CORPUS["changes"]
# The changes that ask, and why: each replaces a file, runs code Nollie can't read, or uses another server's tool
# whose name doesn't say it only reads.
CHANGES_THAT_ASK = [
    ("write_file", "delete"),  # Replaces garden.md, which was there before.
    ("terminal", "unsure"),  # brew install
    ("terminal", "unsure"),  # pip install
    ("terminal", "unsure"),  # npm install
    ("terminal", "delete"),  # echo > budget.md, which was there before.
    ("terminal", "unsure"),  # docker compose up
    ("execute_code", "unsure"),  # subprocess.run(command, shell=True)
    ("mcp__notion__API-patch-page", "unsure"),
    ("mcp__notion__API-post-page", "post"),  # Its name says post; asked before too.
    ("mcp__todoist__add_task", "unsure"),
    ("mcp__github__create_branch", "unsure"),
    ("mcp__filesystem__write_file", "post"),  # "write file" reads as posting a file; asked before too.
    ("mcp__filesystem__create_directory", "unsure"),
    ("mcp__memory__create_entities", "unsure"),
    ("mcp__chrome-devtools__click", "unsure"),  # Asked before too: a click Nollie can't read.
]


class Screen:
    def __init__(self, seen=None):
        self.seen = seen or {}

    def label_at(self, tool, args):
        return self.seen.get("label", ask_first.UNREADABLE)

    def text(self, tool, args):
        return self.seen.get("text", ask_first.UNREADABLE)

    def around(self, tool, args):
        return self.seen.get("around", self.seen.get("text", ask_first.UNREADABLE))


class Files:
    """Files that are there already, by full path; a relative path is read from /Users/sam."""

    def __init__(self, existing=(), folders=()):
        self.existing, self.folders = set(existing), set(folders)

    @staticmethod
    def _full(path, cwd=None):
        path = path.replace("~", "/Users/sam", 1) if path.startswith("~") else path
        return path if path.startswith("/") else os.path.join(cwd or "/Users/sam", path)

    def replaces(self, path, cwd=None):
        full = self._full(path, cwd)
        if full.startswith(("/tmp/", "/private/tmp/")):
            return False
        return full in self.existing

    def folder(self, path, cwd=None):
        full = self._full(path, cwd).rstrip("/")
        return full in self.folders or full.endswith(("/Trips", "/Recipes"))


def run(case, module=ask_first):
    scripts = case.get("script") or {}
    kwargs = {"screen": Screen(case.get("screen")), "read_file": lambda path, cwd: scripts.get(Path(path).name)}
    if module is ask_first:
        kwargs["files"] = Files(case.get("existing", ()))
        kwargs["describe"] = lambda tool: case.get("describe")
    return module.classify(case["tool"], case["args"], **kwargs)


def cards(module=ask_first, cases=CASES):
    return [(case["tool"], json.dumps(case["args"])[:80], found.kind) for case in cases
            for found in [run(case, module)] if found]


class EverydayTests(unittest.TestCase):
    def test_ordinary_work_raises_no_cards(self):
        self.assertGreaterEqual(len(CASES), 80)
        self.assertEqual(cards(), [])

    def test_changes_ask_only_where_expected(self):
        self.assertEqual([(tool, kind) for tool, _, kind in cards(cases=CHANGES)], CHANGES_THAT_ASK)


if __name__ == "__main__":
    for name, cases in (("everyday", CASES), ("changes", CHANGES)):
        for tool, args, kind in cards(cases=cases):
            print(name, kind, tool, args)
