from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from night_support import FakeJobs, job, load

rehearsals = load("rehearsals")


class SignatureTests(unittest.TestCase):
    def setUp(self):
        self.jobs = FakeJobs(scripts={("career", "prices.py"): "print(1)", ("career", "watch.py"): "print(2)"})
        self.hasher = self.jobs.file_hash("career")

    def sign(self, value, saved=None):
        return rehearsals.signature(value, self.hasher, saved)

    def test_each_field_changes_it(self):
        base = job(script=None)
        before = self.sign(base)
        for field, value in (("prompt", "Buy it."), ("schedule", {"kind": "cron", "expr": "0 8 * * *"}),
                             ("enabled_toolsets", ["web", "terminal"]), ("model", "other"),
                             ("deliver", "telegram"), ("failure_deliver", "telegram"), ("skills", ["x"]),
                             ("workdir", "/tmp"), ("script", "prices.py"), ("no_agent", True),
                             ("precheck_fail_closed", True), ("monitor_script", "watch.py"),
                             ("monitor_url", "https://example.com/feed"), ("repeat", {"times": 3})):
            self.assertNotEqual(self.sign(dict(base, **{field: value})), before, field)

    def test_the_scripts_contents_change_it(self):
        value = job(script="prices.py")
        before = self.sign(value)
        self.jobs.scripts[("career", "prices.py")] = "print(2)"
        self.assertNotEqual(self.sign(value), before)
        monitor = job(monitor_script="watch.py")
        before = self.sign(monitor)
        self.jobs.scripts[("career", "watch.py")] = "print(3)"
        self.assertNotEqual(self.sign(monitor), before)

    def test_pausing_and_resuming_leave_it(self):
        value = job()
        before = self.sign(value)
        paused = dict(value, enabled=False, state="paused", paused_at="x", paused_reason="y",
                      next_run_at="z", last_run_at="w", last_status="ok")
        self.assertEqual(self.sign(paused), before)

    def test_held_delivery_comes_from_what_was_saved(self):
        value = job(deliver="bot-chat", failure_deliver="telegram")
        before = self.sign(value)
        held = dict(value, deliver="local", failure_deliver="local")
        saved = {"deliver": "bot-chat", "failure_deliver": "telegram"}
        self.assertEqual(self.sign(held, saved), before)
        self.assertNotEqual(self.sign(held), before)
        # A delivery someone set while held is theirs, not Nollie's local.
        self.assertNotEqual(self.sign(dict(held, deliver="telegram"), saved), before)

    def test_file_hash_stays_inside_the_scripts_folder(self):
        with TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "scripts").mkdir()
            (home / "scripts" / "a.py").write_text("print(1)")
            (home / "secret.txt").write_text("nope")
            digest = rehearsals.file_hash(home)
            self.assertEqual(len(digest("a.py")), 64)
            self.assertEqual(digest("../secret.txt"), "missing")
            self.assertEqual(digest(str(home / "secret.txt")), "missing")
            self.assertEqual(digest("gone.py"), "missing")


class CheckReasonTests(unittest.TestCase):
    def test_reasons(self):
        self.assertIsNone(rehearsals.check_reason(job()))
        self.assertEqual(rehearsals.check_reason(job(script="a.py")), "script")
        self.assertEqual(rehearsals.check_reason(job(no_agent=True)), "script")
        self.assertEqual(rehearsals.check_reason(job(monitor_url="https://x")), "script")
        self.assertEqual(rehearsals.check_reason(job(schedule={"kind": "once", "run_at": "2026-10-21T07:00:00"})), "once")
        self.assertEqual(rehearsals.check_reason(job(repeat={"times": 3, "completed": 0})), "repeat")
        self.assertIsNone(rehearsals.check_reason(job(repeat={"times": None, "completed": 4})))


class RegistryTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def entry(self, **changes):
        value = {"profile": "career", "job_id": "3f2a9c", "title": "Morning prices", "state": "ready",
                 "signature": "a" * 64, "kind": "rehearse", "saved": {"deliver": "bot-chat", "failure_deliver": None},
                 "execution_id": "e-81", "post_id": "rehearsal-career-3f2a9c-e-81", "updated_at": 1}
        value.update(changes)
        return value

    def test_round_trip_and_missing(self):
        self.assertIsNone(rehearsals.read(self.root))
        registry = rehearsals.empty(5)
        registry["jobs"]["career/3f2a9c"] = self.entry()
        rehearsals.write(self.root, registry)
        self.assertEqual(rehearsals.read(self.root, wait=0.5), registry)
        self.assertEqual((self.root / rehearsals.FILE_NAME).stat().st_mode & 0o777, 0o600)

    def test_damaged_is_an_error_not_empty(self):
        for text in ("{", "[]", '{"version": 2, "jobs": {}}', '{"version": 1, "jobs": {"x": {}}}'):
            (self.root / rehearsals.FILE_NAME).write_text(text)
            with self.assertRaises(ValueError, msg=text):
                rehearsals.read(self.root)
        registry = rehearsals.empty()
        registry["jobs"]["career/other"] = self.entry()
        with self.assertRaises(ValueError):
            rehearsals.write(self.root, registry)
        registry["jobs"] = {"career/3f2a9c": self.entry(state="maybe")}
        with self.assertRaises(ValueError):
            rehearsals.write(self.root, registry)
        registry["jobs"] = {}
        registry["pending"] = "career"
        with self.assertRaises(ValueError):
            rehearsals.write(self.root, registry)
        registry["pending"] = ["career"]
        rehearsals.write(self.root, registry)
        self.assertEqual(rehearsals.read(self.root)["pending"], ["career"])

    def test_a_reader_never_creates_the_lock(self):
        rehearsals.read(self.root, wait=0.5)
        self.assertFalse((self.root / rehearsals.LOCK_NAME).exists())


if __name__ == "__main__":
    unittest.main()
