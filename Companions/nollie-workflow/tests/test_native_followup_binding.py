import copy
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_followup_fixture', ROOT/'hermes_support/ollie_cron_followups.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)


class NativeBindingTests(unittest.TestCase):
    def setUp(self):
        self.raw = {'id':'job','enabled':False,'state':'paused','script':None,'route':'original'}
        self.saved = []
        def locked(job_id, apply):
            records = [copy.deepcopy(self.raw)]
            return apply(records,0,records[0])
        jobs = types.SimpleNamespace(_with_job=locked,_normalize_job_record=lambda j:dict(j),
            save_jobs=lambda rows:self.saved.append(copy.deepcopy(rows)),
            _hermes_now=lambda:types.SimpleNamespace(isoformat=lambda:'fixture'))
        scheduler = types.SimpleNamespace(OLLIE_FAIL_CLOSED_PRECHECK_VERSION=1)
        self.patch = patch.dict(sys.modules,{'cron':types.SimpleNamespace(jobs=jobs,scheduler=scheduler)})
        self.patch.start(); self.addCleanup(self.patch.stop)
        self.signature = lambda j:j['route']

    def test_confirmed_binding_is_atomic_and_stays_paused(self):
        result = helper.bind_gate('job','original','fixture.py',self.signature)
        self.assertFalse(result['enabled']); self.assertEqual(result['state'],'paused')
        self.assertTrue(result['precheck_fail_closed']); self.assertEqual(len(self.saved),1)

    def test_resume_or_foreign_script_before_transaction_is_rejected(self):
        for change in [{'enabled':True,'state':'scheduled'},{'script':'foreign.py'},{'route':'edited'}]:
            with self.subTest(change=change):
                previous = dict(self.raw); self.raw.update(change)
                with self.assertRaises(ValueError): helper.bind_gate('job','original','fixture.py',self.signature)
                self.assertFalse(self.saved); self.raw = previous

    def test_unpatched_scheduler_cannot_bind(self):
        with patch.object(helper,'ready',return_value=False):
            with self.assertRaises(RuntimeError): helper.bind_gate('job','original','fixture.py',self.signature)
        self.assertFalse(self.saved)

    def test_stop_compare_and_save_does_not_pause_repurposed_job(self):
        self.raw.update(script='fixture.py',route='edited')
        result = helper.pause_gate('job','original','fixture.py',self.signature,'stop')
        self.assertIsNone(result); self.assertFalse(self.saved)

    def test_stop_preserves_other_native_metadata(self):
        self.raw.update(script='fixture.py',enabled=True,state='scheduled',next_run_at='future',pending_slot='old')
        result = helper.pause_gate('job','original','fixture.py',self.signature,'stop')
        self.assertFalse(result['enabled']); self.assertEqual(result['next_run_at'],'future')
        self.assertNotIn('pending_slot',result)


if __name__ == '__main__': unittest.main()
