"""Run the add-on binding and checked preflight against the pinned Hermes modules."""
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nollie_patch_support",
    ROOT.parent / "hermes-patches/tests/support.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
spec = importlib.util.spec_from_file_location("native_cron_package", ROOT / "__init__.py",
                                             submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = package
spec.loader.exec_module(package)
from native_cron_package.followup_tools import NativeJobs
from native_cron_package.hermes_support import ollie_cron_followups as helper


class NativeCronTests(unittest.TestCase):
    def setUp(self):
        self.home = self.enterContext(support.hermes_source())
        # Config parsing needs optional packages. The scheduler, script runner, wake gate,
        # job lock and job persistence below all come from the checked Hermes source.
        config = types.ModuleType("hermes_cli.config")
        config.load_config = config.load_config_readonly = lambda: {}
        config.InvalidUserConfigError = ValueError
        config.require_parseable_user_config = lambda: None
        config._secure_dir = lambda path: path.chmod(0o700)
        config._secure_file = lambda path: path.chmod(0o600)
        sys.modules["hermes_cli.config"] = config
        sys.modules["hermes_yaml"] = types.ModuleType("hermes_yaml")
        self.scheduler = support.hermes_module("cron.scheduler")
        self.jobs = support.hermes_module("cron.jobs")
        self.job = {"id": "fixture", "prompt": "Check the fixture", "model": "fixture-model",
                    "enabled": False, "state": "paused", "schedule": {"kind": "interval", "minutes": 60},
                    "next_run_at": "2099-01-01T09:00:00+00:00", "fixture_metadata": "kept"}

    def prepare(self, job, script_result):
        with patch.object(self.scheduler, "_run_job_script_with_claim_heartbeat", return_value=script_result) as run, \
                patch.object(self.scheduler, "_build_job_prompt", return_value="fixture prompt") as build, \
                patch.object(self.scheduler, "note_cron_skipped"):
            result = self.scheduler._prepare_job_prompt(job, "fixture", "Fixture", None, None)
        return result, run, build

    def test_missing_script_field_stops_before_prompt_or_agent(self):
        with patch.object(self.scheduler, "_build_job_prompt") as build, \
                patch.object(self.scheduler, "_construct_cron_agent") as construct:
            result = self.scheduler.run_job(dict(self.job, precheck_fail_closed=True))
        self.assertFalse(result[0])
        self.assertIn("missing", result[3])
        build.assert_not_called()
        construct.assert_not_called()
        self.assertNotIn("run_agent", sys.modules)

    def test_missing_file_uses_real_script_runner_and_stops(self):
        with patch.object(self.scheduler, "_build_job_prompt") as build:
            result = self.scheduler.run_job(dict(self.job, script="missing-fixture.py", precheck_fail_closed=True))
        self.assertFalse(result[0])
        self.assertIn("failed", result[3])
        build.assert_not_called()
        self.assertNotIn("run_agent", sys.modules)

    def test_failed_script_or_timeout_cannot_build_prompt(self):
        for failure in ("Script exited with code 1", "Script timed out", "Interpreter unavailable"):
            with self.subTest(failure=failure):
                job = dict(self.job, script="fixture.py", precheck_fail_closed=True)
                (early, prompt), run, build = self.prepare(job, (False, failure))
                self.assertFalse(early[0])
                self.assertEqual(early[2], "")
                self.assertIsNone(prompt)
                run.assert_called_once()
                build.assert_not_called()

    def test_native_wake_gate_preserves_silent_and_ready_outcomes(self):
        job = dict(self.job, script="fixture.py", precheck_fail_closed=True)
        (early, prompt), run, build = self.prepare(job, (True, '{"wakeAgent":false}'))
        self.assertTrue(early[0])
        self.assertEqual(early[2], "[SILENT]")
        self.assertIsNone(prompt)
        run.assert_called_once()
        build.assert_not_called()
        (early, prompt), run, build = self.prepare(job, (True, '{"wakeAgent":true}'))
        self.assertIsNone(early)
        self.assertEqual(prompt, "fixture prompt")
        run.assert_called_once()
        self.assertEqual(build.call_args.kwargs["prerun_script"], (True, '{"wakeAgent":true}'))

    def test_ordinary_jobs_keep_native_script_failure_behavior(self):
        (early, prompt), _, build = self.prepare(dict(self.job, script="fixture.py"), (False, "failed"))
        self.assertIsNone(early)
        self.assertEqual(prompt, "fixture prompt")
        build.assert_called_once()

    def test_addon_binding_and_pause_use_native_locked_store(self):
        self.assertTrue(helper.ready())
        self.jobs.save_jobs([self.job])
        native = NativeJobs(self.home)
        expected = native.route_signature(native.get("fixture"))
        bound = native.bind_gate("fixture", expected, "fixture.py")
        self.assertTrue(bound["precheck_fail_closed"])
        self.assertFalse(bound["enabled"])
        self.assertEqual(bound["state"], "paused")
        self.assertEqual(self.jobs.get_job("fixture")["script"], "fixture.py")
        paused = native.pause_gate("fixture", expected, "fixture.py", "finished")
        self.assertEqual(paused["paused_reason"], "finished")
        self.assertEqual(paused["next_run_at"], self.job["next_run_at"])
        self.assertEqual(paused["fixture_metadata"], "kept")
        self.assertEqual(self.jobs.get_job("fixture")["paused_reason"], "finished")
        self.assertNotIn("hermes_cli.ollie_cron_followups", sys.modules)

    def test_addon_refuses_changed_or_resumed_native_job(self):
        for change in ({"model": "different"}, {"enabled": True, "state": "scheduled"},
                       {"script": "other.py"}):
            with self.subTest(change=change):
                self.jobs.save_jobs([dict(self.job, **change)])
                before = (self.home / "cron/jobs.json").read_bytes()
                with self.assertRaises(ValueError):
                    helper.bind_gate("fixture", "fixture-model", "fixture.py", lambda job: job["model"])
                self.assertEqual((self.home / "cron/jobs.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
