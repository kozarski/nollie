"""The crew against Hermes's own profile and cron code, in a temporary home.

Runs only under Hermes's Python (see the README); elsewhere it is skipped.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

HERE = Path(__file__).resolve().parent
HERMES = importlib.util.find_spec("hermes_cli") is not None
SCRIPTED = HERMES and importlib.util.find_spec("tests.fakes.fake_llm_provider") is not None


def hermetic_env(temp):
    home = Path(temp) / "home"
    (home / ".hermes").mkdir(parents=True)
    keep = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "TMPDIR", "PYTHONPATH")}
    return dict(keep, HOME=str(home), HERMES_HOME=str(home / ".hermes"), CREW_SCENARIO_TMP=str(Path(temp).resolve()),
                PYTHONDONTWRITEBYTECODE="1", NO_COLOR="1")


@unittest.skipUnless(HERMES, "Hermes's Python and source are on the path")
class HermesProfileTests(unittest.TestCase):
    def test_add_pause_retire_undo_with_hermes_profiles(self):
        with TemporaryDirectory() as temp:
            run = subprocess.run([sys.executable, str(HERE / "hermes_scenario.py")], env=hermetic_env(temp),
                                 capture_output=True, text=True, timeout=300, cwd=temp)
            self.assertEqual(run.returncode, 0, run.stderr[-4000:])
            seen = json.loads(run.stdout.strip().splitlines()[-1])
        self.assertEqual(seen["caller"], {"profile": "default", "helper": False, "scheduled": False})
        self.assertFalse(seen["clash"]["ok"])
        self.assertEqual(seen["added"]["status"], "added", seen["added"])
        self.assertEqual(seen["added"]["note"], "I've added Rover to check new roles each morning.")
        self.assertIn("rover", seen["names_after_add"])
        self.assertEqual(seen["meta"]["display_name"], "Rover")
        self.assertEqual(seen["meta"]["description"], "New job listings.")
        self.assertEqual(seen["model"], {"provider": "llamacpp"})  # never the plan Hermes seeded
        self.assertEqual(seen["exceeds"], [])
        self.assertNotIn("computer_use", seen["cli_tools"])
        self.assertFalse(seen["wrapper"])
        self.assertEqual(seen["job"], {"enabled": True, "state": "scheduled", "deliver": "local"})
        self.assertEqual(seen["pause"]["status"], "paused")
        self.assertTrue(seen["parked"])
        self.assertFalse(seen["job_paused"])
        self.assertNotIn("rover", seen["served_while_parked"])
        self.assertEqual(seen["ask_retire"], "needs_confirmation")
        self.assertEqual(seen["retired"], "retired")
        self.assertNotIn("rover", seen["names_after_retire"])
        self.assertEqual(seen["archives"], [True])
        self.assertEqual(seen["back"], "active")
        self.assertIn("rover", seen["names_after_undo"])
        self.assertTrue(seen["job_after_undo"])
        self.assertEqual(seen["undo_add"], "removed")
        self.assertEqual(sorted(seen["names_at_end"]), ["career", "default", "private"])
        self.assertTrue(seen["private_untouched"])


@unittest.skipUnless(SCRIPTED, "Hermes's scripted model (tests/fakes in the Hermes source) is on the path")
class ScriptedConversationTests(unittest.TestCase):
    def test_nollie_adds_and_retires_a_member_in_real_hermes_turns(self):
        with TemporaryDirectory() as temp:
            run = subprocess.run([sys.executable, str(HERE / "scripted_run.py")], env=hermetic_env(temp), capture_output=True,
                                 text=True, timeout=900, cwd=temp)
            self.assertEqual(run.returncode, 0, run.stderr[-4000:])
            seen = json.loads(run.stdout.strip().splitlines()[-1])
        self.assertEqual(seen["install"], 0)
        self.assertTrue(seen["first_done"], seen.get("stderr"))
        self.assertEqual(seen["add_result"]["note"], "I've added Rover to check new roles each morning.")
        self.assertEqual([a["id"] for a in seen["add_result"]["actions"]], ["meet", "undo"])
        self.assertTrue(seen["profile_after_add"])
        self.assertEqual(seen["retire_results"], ["needs_confirmation", "retired"])
        self.assertFalse(seen["profile_after_retire"])
        self.assertEqual(seen["archives"], 1)
        self.assertEqual(len(seen["mac_results"]), 1)
        self.assertIn("requires approval (Nollie wants to add Pixel and let them use the Mac.)", seen["mac_results"][0])
        self.assertFalse(seen["mac_profile"])


if __name__ == "__main__":
    unittest.main()
