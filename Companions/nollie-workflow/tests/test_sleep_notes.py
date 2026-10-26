"""Sleep notes: the gaps the service sees between its ticks, and what the morning card says ran late or was
skipped while the Mac was asleep or off. Never that a run ran when it didn't."""
from datetime import datetime
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from night_support import Clock, FakeJobs, execution, job, load

sleep_watch = load("sleep_watch")
night = load("night_shift")
service = load("night_service")
recorder = load("recorder")
core = load("workflow_core")

MORNING = int(datetime(2026, 10, 21, 7, 30).timestamp())
NIGHT = MORNING - 9 * 3600
PRIVATE = frozenset({"private", "moss"})


class Clocks:
    """Wall time, seconds awake and seconds since boot, moved by the test."""

    def __init__(self, wall=NIGHT, boot=NIGHT - 3600):
        self.wall, self.boot, self.asleep = float(wall), float(boot), 0.0

    def __call__(self):
        running = self.wall - self.boot
        return self.wall, running - self.asleep, running

    def run(self, seconds):
        self.wall += seconds

    def sleep(self, seconds):
        self.wall += seconds
        self.asleep += seconds


class WatchCase(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "nollie-workflow"
        self.clocks = Clocks()

    def watch(self):
        return sleep_watch.SleepWatch(self.root, clocks=self.clocks)


class SleepWatchTests(WatchCase):
    def test_steady_ticks_find_nothing(self):
        watch = self.watch()
        for _ in range(40):
            self.assertEqual(watch.tick(), [])
            self.clocks.run(15)
        self.assertEqual(sleep_watch.read(self.root)["gaps"], [])

    def test_a_night_asleep_is_one_gap_from_the_last_tick_for_as_long_as_it_slept(self):
        watch = self.watch()
        watch.tick()
        before = int(self.clocks.wall)
        self.clocks.run(5)
        self.clocks.sleep(5 * 3600)
        self.clocks.run(10)
        # Somewhere between two ticks: it is put at the first one, for as long as it lasted.
        self.assertEqual(watch.tick(), [{"from": before, "to": before + 5 * 3600, "kind": "asleep"}])
        self.assertEqual(len(sleep_watch.read(self.root)["gaps"]), 1)

    def test_a_short_nap_or_a_slow_tick_is_not_a_gap(self):
        watch = self.watch()
        watch.tick()
        self.clocks.sleep(sleep_watch.MIN_GAP - 1)
        self.assertEqual(watch.tick(), [])
        # Busy for minutes but awake the whole time: not asleep.
        self.clocks.run(900)
        self.assertEqual(watch.tick(), [])

    def test_hermes_stopped_while_the_mac_stayed_on(self):
        self.watch().tick()
        seen = int(self.clocks.wall)
        self.clocks.run(2 * 3600)
        self.assertEqual(self.watch().tick(), [{"from": seen, "to": seen + 2 * 3600, "kind": "stopped"}])

    def test_the_mac_was_off_then_on_without_hermes(self):
        self.watch().tick()
        seen = int(self.clocks.wall)
        self.clocks.run(4 * 3600)
        self.clocks.boot = self.clocks.wall
        self.clocks.asleep = 0
        self.clocks.run(600)
        self.assertEqual(self.watch().tick(), [{"from": seen, "to": seen + 4 * 3600, "kind": "off"},
                                               {"from": seen + 4 * 3600, "to": seen + 4 * 3600 + 600, "kind": "stopped"}])

    def test_a_quick_restart_keeps_only_what_lasted(self):
        self.watch().tick()
        seen = int(self.clocks.wall)
        self.clocks.run(60)
        self.clocks.boot = self.clocks.wall
        self.clocks.run(3600)
        self.assertEqual(self.watch().tick(), [{"from": seen + 60, "to": seen + 3660, "kind": "stopped"}])

    def test_the_stamp_is_written_at_most_once_a_minute(self):
        watch = self.watch()
        watch.tick()
        first = sleep_watch.read(self.root)["seen"]["at"]
        self.clocks.run(15)
        watch.tick()
        self.assertEqual(sleep_watch.read(self.root)["seen"]["at"], first)
        self.clocks.run(60)
        watch.tick()
        self.assertEqual(sleep_watch.read(self.root)["seen"]["at"], first + 75)

    def test_without_both_clocks_a_late_tick_counts(self):
        wall = [float(NIGHT)]
        watch = sleep_watch.SleepWatch(self.root, clocks=lambda: (wall[0], None, None))
        watch.tick()
        wall[0] += 3600
        self.assertEqual([g["kind"] for g in watch.tick()], ["asleep"])

    def test_a_damaged_or_linked_file_reads_as_empty_and_is_replaced(self):
        self.root.mkdir(parents=True)
        (self.root / sleep_watch.FILE_NAME).write_text("{not json")
        self.assertEqual(sleep_watch.read(self.root), {"version": 1, "seen": None, "gaps": []})
        self.watch().tick()
        self.assertIsNotNone(sleep_watch.read(self.root)["seen"])
        (self.root / sleep_watch.FILE_NAME).unlink()
        (self.root / sleep_watch.FILE_NAME).symlink_to(self.root / "elsewhere.json")
        self.assertEqual(sleep_watch.read(self.root)["gaps"], [])

    def test_bounded_and_cut_to_a_window(self):
        now = NIGHT + 40 * 86400
        old = {"from": NIGHT, "to": NIGHT + 600, "kind": "asleep"}
        recent = {"from": now - 7200, "to": now - 3600, "kind": "asleep"}
        core.atomic_write(self.root / sleep_watch.FILE_NAME, {"version": 1, "seen": None, "gaps": [old, recent]})
        self.clocks.wall = float(now)
        self.watch().tick()
        self.assertEqual(sleep_watch.read(self.root)["gaps"], [recent])
        self.assertEqual(sleep_watch.gaps(self.root, now - 5000, now),
                         [{"from": now - 5000, "to": now - 3600, "kind": "asleep"}])
        self.assertEqual(sleep_watch.gaps(self.root, now - 3000, now), [])

    def test_the_file_is_private(self):
        self.watch().tick()
        self.assertEqual((self.root / sleep_watch.FILE_NAME).stat().st_mode & 0o777, 0o600)


class OccurrenceTests(unittest.TestCase):
    def test_times_inside_the_window_only(self):
        hourly = lambda t: (t // 3600 + 1) * 3600
        self.assertEqual(night.occurrences(hourly, 7200, 7200 + 3 * 3600), [7200, 10800, 14400])

    def test_a_bounded_list_and_a_schedule_that_never_moves_on(self):
        self.assertEqual(len(night.occurrences(lambda t: t + 60, 0, 10**9)), night.MAX_MISSED)
        self.assertEqual(night.occurrences(lambda t: 5, 10, 100), [])
        self.assertEqual(night.occurrences(lambda t: None, 10, 100), [])

        def broken(t):
            raise ValueError("bad expression")
        self.assertEqual(night.occurrences(broken, 10, 100), [])


class CardTests(unittest.TestCase):
    """The morning card's sleep fields, from the builder."""

    def card(self, lines, jobs, due, sleep):
        bots = {"default": {"name": "Nollie", "lines": lines, "jobs": jobs, "unrecorded": {}, "watched": True,
                            "due": due}}
        return night.night_card(day="2026-10-21", window=(NIGHT, MORNING), bots=bots, outcomes=[], grants=[],
                                unwatched=[], private=PRIVATE, redactor=lambda t: t, sleep=sleep)

    def test_a_run_that_waited_for_the_mac_and_the_times_it_missed(self):
        asleep = {"from": NIGHT + 3600, "to": NIGHT + 6 * 3600, "kind": "asleep"}
        woke = asleep["to"] + 40
        lines = [{"v": 1, "at": woke, "run": "cron:hourly:e-9", "event": "start", "kind": "schedule",
                  "job_id": "hourly", "execution_id": "e-9", "title": "Hourly check", "due_at": NIGHT + 2 * 3600},
                 {"v": 1, "at": woke + 30, "run": "cron:hourly:e-9", "event": "end", "outcome": "done"},
                 {"v": 1, "at": NIGHT + 600, "run": "cron:daily:e-1", "event": "start", "kind": "schedule",
                  "job_id": "daily", "execution_id": "e-1", "title": "Daily", "due_at": NIGHT + 590},
                 {"v": 1, "at": NIGHT + 660, "run": "cron:daily:e-1", "event": "end", "outcome": "done"}]
        dues = [NIGHT + h * 3600 for h in range(2, 6)]
        post = self.card(lines, [job("hourly", name="Hourly check"), job("daily", name="Daily")], {"hourly": dues},
                         [asleep])
        self.assertEqual(post["sleep"], [asleep])
        runs = {r["id"]: r for r in post["runs"]}
        self.assertEqual(runs["cron:hourly:e-9"]["due_at"], NIGHT + 2 * 3600)
        self.assertTrue(runs["cron:hourly:e-9"]["late"])
        self.assertEqual(runs["cron:hourly:e-9"]["outcome"], "done")
        self.assertNotIn("late", runs["cron:daily:e-1"])
        # It ran once for its first missed time; the other three were skipped, and never counted as runs.
        self.assertEqual(post["missed"], [{"bot": "default", "bot_name": "Nollie", "job_id": "hourly",
                                           "title": "Hourly check", "first_due": NIGHT + 3 * 3600,
                                           "last_due": NIGHT + 5 * 3600, "count": 3}])
        self.assertEqual(post["counts"]["runs"], 2)

    def test_nothing_ran_while_asleep_and_nothing_was_due(self):
        asleep = {"from": NIGHT, "to": NIGHT + 3600, "kind": "asleep"}
        post = self.card([], [job("daily")], {}, [asleep])
        self.assertEqual(post["sleep"], [asleep])
        self.assertNotIn("missed", post)
        self.assertEqual(post["note"], night.QUIET)

    def test_a_gated_run_takes_its_due_time_from_hermes(self):
        ran = NIGHT + 7 * 3600
        record = job("gated", last_run_at=datetime.fromtimestamp(ran).astimezone().isoformat(),
                     last_dispatch={"scheduled_at": datetime.fromtimestamp(NIGHT + 3600).astimezone().isoformat(),
                                    "dispatched_at": datetime.fromtimestamp(ran - 5).astimezone().isoformat(),
                                    "kind": "catch_up"})
        post = self.card([], [record], {"gated": [NIGHT + 3600]},
                         [{"from": NIGHT + 1800, "to": NIGHT + 6 * 3600, "kind": "off"}])
        self.assertEqual(post["runs"][0]["due_at"], NIGHT + 3600)
        self.assertTrue(post["runs"][0]["late"])
        self.assertNotIn("missed", post)

    def test_no_sleep_no_fields(self):
        post = self.card([], [job("daily")], {}, [])
        self.assertNotIn("sleep", post)
        self.assertNotIn("missed", post)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.root = self.home / "nollie-workflow"
        self.clock = Clock(MORNING)
        self.clocks = Clocks(wall=MORNING)
        self.jobs = DueJobs({"default": [job("hourly", name="Hourly check")],
                             "career": [job("paused1", enabled=False, state="paused")],
                             "private": [job("secret1", name="Moss diary")]},
                            names={"default": "Nollie", "career": "Scout"})
        self.service = service.NightService(self.home, self.jobs, now=self.clock, private=lambda: PRIVATE,
                                            redactor=lambda text: text, clocks=self.clocks)
        for profile in ("default", "career"):
            core.atomic_write(self.root / "recorders" / (profile + ".json"), {"version": 1, "pid": 1, "at": 1})
        night.write_settings(self.root, night_shift=True)

    def asleep_until(self, woke):
        core.atomic_write(self.root / sleep_watch.FILE_NAME, {"version": 1, "seen": None, "gaps": [
            {"from": NIGHT + 3600, "to": woke, "kind": "asleep"}]})

    def test_the_card_waits_until_what_waited_has_run(self):
        self.asleep_until(MORNING - 60)
        self.service.tick()
        self.assertIsNone(self.service.posts.get("night-2026-10-21"))
        self.clock.value = MORNING - 60 + service.SETTLE_AFTER_WAKE
        self.clocks.run(service.SETTLE_AFTER_WAKE)
        self.service.tick()
        post = self.service.posts.get("night-2026-10-21")
        self.assertEqual(post["sleep"], [{"from": NIGHT + 3600, "to": MORNING - 60, "kind": "asleep"}])
        # Hourly, never ran: every hour while asleep was skipped. The paused one was never due.
        self.assertEqual([(m["job_id"], m["count"]) for m in post["missed"]], [("hourly", 8)])
        self.assertNotIn("private", json.dumps(self.jobs.asked))


class DueJobs(FakeJobs):
    """Hourly due times, the way the adapter asks Hermes for them."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.asked = []

    def due_times(self, profile, job, start, end):
        if profile in PRIVATE:
            raise AssertionError("a private bot's schedules were read")
        self.asked.append((profile, job["id"]))
        return night.occurrences(lambda t: (t // 3600 + 1) * 3600, start, end)


class RecorderDueTests(unittest.TestCase):
    def test_a_schedule_runs_start_line_says_when_it_was_due(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        home = Path(temp.name)
        root = home / "nollie-workflow"
        night.write_settings(root, night_shift=True)
        due = datetime.fromtimestamp(NIGHT).astimezone()
        for instant, expected in ((due.isoformat(), NIGHT), (due, NIGHT), (None, None), ("not a time", None)):
            rec = recorder.Recorder(root=root, profile="career", main_home=home,
                                    cron=lambda: execution(scheduled_instant=instant),
                                    session_env=lambda name: "", environ={}, jobs=FakeJobs({"career": [job()]}),
                                    private=lambda: frozenset(), clock=Clock(MORNING), monotonic=Clock(MORNING))
            run = rec.identify(task_id="cron:3f2a9c:e-81")
            self.assertEqual(run.get("due"), expected)


if __name__ == "__main__":
    unittest.main()
