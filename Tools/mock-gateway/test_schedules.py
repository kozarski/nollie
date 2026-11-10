import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("schedules_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class ScheduleFixtureTests(unittest.TestCase):
    def setUp(self):
        self.original = copy.deepcopy(mock.CRON_JOBS)
        mock.PASSWORD_AUTH["enabled"] = False

    def tearDown(self):
        mock.CRON_JOBS[:] = self.original

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def test_list_is_cross_profile_until_a_profile_is_requested(self):
        status, result = self.request("/api/cron/jobs")
        self.assertEqual(status, 200)
        self.assertEqual({job["profile"] for job in result["jobs"]}, {"default", "work"})
        _, scoped = self.request("/api/cron/jobs?profile=work")
        self.assertEqual([job["job_id"] for job in scoped["jobs"]], ["dep-audit"])

    def test_create_records_the_chosen_bot_and_deletes_only_its_job(self):
        payload = {"name": "Demo daily plan", "prompt": "List today's demo tasks.", "schedule": "0 9 * * *", "deliver": "bot-chat"}
        status, created = self.request("/api/cron/jobs?profile=work", "POST", payload)
        self.assertEqual(status, 200)
        self.assertEqual(created["profile"], "work")
        for key, value in payload.items():
            self.assertEqual(created[key], value)
        self.assertEqual(self.request("/api/cron/jobs/" + created["job_id"])[1], created)
        self.assertEqual(self.request("/api/cron/jobs/" + created["job_id"], "DELETE")[0], 200)
        self.assertEqual(mock.CRON_JOBS, self.original)

    def test_incomplete_or_unscoped_create_never_writes(self):
        for path, body in (("/api/cron/jobs", {"prompt": "Demo", "schedule": "0 9 * * *"}),
                           ("/api/cron/jobs?profile=work", {"prompt": "   ", "schedule": "0 9 * * *"}),
                           ("/api/cron/jobs?profile=work", {"prompt": "Demo"})):
            self.assertEqual(self.request(path, "POST", body)[0], 400)
        self.assertEqual(mock.CRON_JOBS, self.original)

    def test_once_returns_the_gateway_schedule_object_and_one_run(self):
        payload = {"name": "Demo follow-up", "prompt": "Check the demo task.",
                   "schedule": "2027-11-05T14:30:00Z", "deliver": "bot-chat"}
        status, created = self.request("/api/cron/jobs?profile=work", "POST", payload)
        self.assertEqual(status, 200)
        self.assertEqual(created["schedule"]["kind"], "once")
        self.assertEqual(created["schedule"]["run_at"], "2027-11-05T14:30:00+00:00")
        self.assertEqual(created["repeat"], {"times": 1, "completed": 0})
        self.assertEqual(created["profile"], "work")

    def test_pause_resume_confirms_state_without_running_or_changing_instructions(self):
        before = copy.deepcopy(mock._cron_job("morning-brief"))
        triggers = len(mock.CRON_TRIGGERS)
        status, paused = self.request("/api/cron/jobs/morning-brief/pause?profile=default", "POST")
        self.assertEqual(status, 200)
        self.assertFalse(paused["enabled"])
        self.assertEqual(paused["state"], "paused")
        status, resumed = self.request("/api/cron/jobs/morning-brief/resume?profile=default", "POST")
        self.assertEqual(status, 200)
        self.assertTrue(resumed["enabled"])
        self.assertEqual(resumed, before)
        self.assertEqual(len(mock.CRON_TRIGGERS), triggers)

    def test_wrong_profile_never_mutates_a_schedule(self):
        status, _ = self.request("/api/cron/jobs/morning-brief/pause?profile=work", "POST")
        self.assertEqual(status, 404)
        self.assertEqual(mock.CRON_JOBS, self.original)

    def test_instruction_edit_preserves_last_result_and_schedule(self):
        before = copy.deepcopy(mock._cron_job("morning-brief"))
        status, saved = self.request("/api/cron/jobs/morning-brief?profile=default", "PUT", {"updates": {"prompt": "Only meaningful changes. Stop after 30 days."}})
        self.assertEqual(status, 200)
        self.assertEqual(saved["prompt"], "Only meaningful changes. Stop after 30 days.")
        for key, value in before.items():
            self.assertEqual(saved[key], value)

    def test_a_run_in_flight_is_listed_and_stop_ends_only_that_run(self):
        job = mock._cron_job("morning-brief")
        job["live_execution"] = mock._live_execution("morning-brief", 1_800_000_000)
        _, listed = self.request("/api/cron/jobs")
        running = [j["job_id"] for j in listed["jobs"] if j.get("live_execution")]
        self.assertEqual(running, ["morning-brief"])
        self.assertEqual(listed["jobs"][0]["live_execution"]["status"], "running")

        status, answer = self.request("/api/cron/jobs/morning-brief/cancel?profile=default", "POST")
        self.assertEqual(status, 200)
        self.assertEqual(answer["cancelled"], True)
        self.assertEqual(answer["execution_id"], "exec-morning-brief-1800000000")
        self.assertEqual(answer["job_id"], "morning-brief")
        # The schedule stays on; only the run ended.
        self.assertTrue(job["enabled"])
        self.assertEqual(job["state"], "active")
        self.assertIsNone(job["live_execution"])

        status, again = self.request("/api/cron/jobs/morning-brief/cancel", "POST")
        self.assertEqual(status, 200)
        self.assertEqual(again["cancelled"], False)
        self.assertIsNone(again["execution_id"])

    def test_a_flow_can_start_and_end_a_run(self):
        status, job = self.request("/api/_mock/schedule-run", "POST", {"job_id": "morning-brief", "seconds_ago": 60})
        self.assertEqual(status, 200)
        self.assertEqual(job["live_execution"]["status"], "running")
        _, job = self.request("/api/_mock/schedule-run", "POST", {"job_id": "morning-brief", "running": False})
        self.assertIsNone(job["live_execution"])

    def test_stop_for_another_bot_or_a_missing_job_is_refused(self):
        self.assertEqual(self.request("/api/cron/jobs/morning-brief/cancel?profile=work", "POST")[0], 404)
        self.assertEqual(self.request("/api/cron/jobs/nope/cancel", "POST")[0], 404)
        self.assertEqual(mock.CRON_JOBS, self.original)

    def test_the_missed_run_rule_is_saved_and_checked(self):
        status, saved = self.request("/api/cron/jobs/morning-brief?profile=default", "PUT", {"updates": {"catch_up": False}})
        self.assertEqual(status, 200)
        self.assertIs(saved["catch_up"], False)
        self.assertEqual(self.request("/api/cron/jobs/morning-brief", "PUT", {"updates": {"catch_up": "yes"}})[0], 400)


if __name__ == "__main__":
    unittest.main()
