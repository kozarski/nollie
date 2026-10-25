from datetime import datetime, timedelta
import multiprocessing
from pathlib import Path
from tempfile import TemporaryDirectory
import time
import unittest

import support

modules = support.load()
limits = modules["limits"]


class Clock:
    def __init__(self, start=None):
        self.now = start or datetime(2026, 10, 19, 21, 0).timestamp()
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(round(seconds, 3))
        self.now += seconds


def _take(root, count, queue):
    import support as s
    module = s.load()["limits"]
    service = module.ServiceLimits(root, services={"exa": {"interval": 0.0, "daily": 45}})
    taken = 0
    for _ in range(count):
        try:
            service.acquire("exa")
            taken += 1
        except module.Resting:
            pass
    queue.put(taken)


def _pace(root, queue):
    import support as s
    module = s.load()["limits"]
    pacer = module.HostPacer(root, interval=0.3)
    stamps = []
    for _ in range(3):
        pacer.wait_turn("shared.example.com", max_wait=10)
        stamps.append(time.time())
    queue.put(stamps)


class ServiceLimitTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.clock = Clock()

    def make(self, **services):
        return limits.ServiceLimits(self.root, clock=self.clock, sleep=self.clock.sleep, services=services)

    def test_about_one_request_a_second(self):
        service = self.make()
        start = self.clock.now
        service.acquire("exa")
        service.acquire("exa")
        service.acquire("exa")
        self.assertAlmostEqual(self.clock.now - start, 2.0)

    def test_parallel_requests_from_another_bot_share_the_queue(self):
        first, second = self.make(), self.make()
        first.acquire("exa")
        second.acquire("exa")
        self.assertEqual(self.clock.sleeps, [1.0])

    def test_exa_cap_stays_under_fifty_and_rests_until_tomorrow(self):
        self.assertLess(limits.SERVICES["exa"]["daily"], 50)
        service = self.make(exa={"interval": 0, "daily": 3})
        for _ in range(3):
            service.acquire("exa")
        with self.assertRaises(limits.Resting) as caught:
            service.acquire("exa")
        self.assertIn("quota exceeded", caught.exception.message)
        self.assertIn("tomorrow", caught.exception.message)
        self.clock.now += 3600  # later the same evening: still resting
        with self.assertRaises(limits.Resting):
            service.acquire("exa")
        tomorrow = datetime.fromtimestamp(self.clock.now) + timedelta(days=1)
        self.clock.now = tomorrow.replace(hour=0, minute=1).timestamp()
        service.acquire("exa")  # a new day: rested and counted afresh
        self.assertEqual(service.status()["exa"]["used_today"], 1)

    def test_slow_down_backs_off_and_doubles(self):
        service = self.make()
        service.acquire("keenable")
        service.report("keenable", "slow")
        with self.assertRaises(limits.Resting) as caught:
            service.acquire("keenable")
        self.assertIn("slow down", caught.exception.message)
        self.clock.now += limits.FIRST_BACKOFF + 1
        service.acquire("keenable")
        service.report("keenable", "slow")
        self.clock.now += limits.FIRST_BACKOFF + 1
        with self.assertRaises(limits.Resting):
            service.acquire("keenable")  # second pause is twice as long
        self.clock.now += limits.FIRST_BACKOFF
        service.acquire("keenable")
        service.report("keenable", "ok")
        service.acquire("keenable")

    def test_retry_after_is_honoured(self):
        service = self.make()
        service.report("parallel", "slow", retry_after=600)
        self.clock.now += 300
        with self.assertRaises(limits.Resting):
            service.acquire("parallel")
        self.clock.now += 301
        service.acquire("parallel")

    def test_quota_reply_rests_until_the_next_day(self):
        service = self.make()
        service.report("firecrawl", "quota")
        self.assertIsNotNone(service.status()["firecrawl"]["resting_until"])
        self.clock.now += 6 * 3600
        service.acquire("firecrawl")

    def test_will_not_wait_forever(self):
        service = self.make(github={"interval": 60, "daily": 100})
        service.acquire("github")
        with self.assertRaises(limits.Resting) as caught:
            service.acquire("github", max_wait=5)
        self.assertIn("busy", caught.exception.message)

    def test_failure_text_classification(self):
        self.assertEqual(limits.classify_failure("HTTP 429: Too Many Requests"), "slow")
        self.assertEqual(limits.classify_failure("free tier daily limit reached"), "quota")
        self.assertEqual(limits.classify_failure("HTTP 400: bad query"), None)

    def test_daily_cap_holds_across_processes(self):
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        workers = [context.Process(target=_take, args=(str(self.root), 30, queue)) for _ in range(2)]
        for worker in workers:
            worker.start()
        totals = [queue.get(timeout=60) for _ in workers]
        for worker in workers:
            worker.join(timeout=60)
        self.assertEqual(sum(totals), 45)


class HostPacerTests(unittest.TestCase):
    def test_spacing_holds_across_processes(self):
        with TemporaryDirectory() as temporary:
            context = multiprocessing.get_context("spawn")
            queue = context.Queue()
            workers = [context.Process(target=_pace, args=(temporary, queue)) for _ in range(2)]
            for worker in workers:
                worker.start()
            stamps = sorted(s for _ in workers for s in queue.get(timeout=60))
            for worker in workers:
                worker.join(timeout=60)
        gaps = [b - a for a, b in zip(stamps, stamps[1:])]
        self.assertEqual(len(stamps), 6)
        # Each stamp is taken just after the turn, so a busy machine can shave a little off a gap;
        # without pacing the two processes would land within milliseconds of each other.
        self.assertGreaterEqual(min(gaps), 0.2)

    def test_rest_after_slow_down(self):
        with TemporaryDirectory() as temporary:
            clock = Clock()
            pacer = limits.HostPacer(temporary, clock=clock, sleep=clock.sleep)
            pacer.rest("slow.example.com", 120)
            with self.assertRaises(limits.Resting):
                pacer.wait_turn("slow.example.com")
            pacer.wait_turn("other.example.com")
            clock.now += 121
            pacer.wait_turn("slow.example.com")


if __name__ == "__main__":
    unittest.main()
