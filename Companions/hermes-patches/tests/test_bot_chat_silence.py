"""Quiet deliveries through the pinned mailbox, completion and history code.

Provider setup and unused config readers are replaced at import boundaries. The
receipt files, marker matching, metadata, completion and resume functions are real.
"""
import builtins
import contextlib
import copy
import inspect
import logging
import os
import subprocess
import sys
import threading
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

from support import hermes_module, hermes_source


def stub(name, **values):
    module = ModuleType(name)
    vars(module).update(values)
    sys.modules[name] = module
    return module


class BotChatSilenceTests(unittest.TestCase):
    def setUp(self):
        self.home = self.enterContext(hermes_source())
        self.silence = hermes_module('agent.bot_chat_silence')
        # Mailbox file IO never parses YAML. Keep a missing optional parser from
        # pulling in profile configuration just to import the shared file helpers.
        stub('hermes_yaml')

    def owner(self):
        return dict(profile_home=str(self.home.resolve()), session_id='fixture-session',
                    live_session_id='fixture-live', lease_id='fixture-lease')

    def test_machine_markers_keep_their_original_text_and_metadata(self):
        metadata = hermes_module('agent.message_metadata')
        for text in ('[SILENT]', 'NO_REPLY', ' *NO_REPLY* ', 'SILENT'):
            with self.subTest(text=text):
                agent = SimpleNamespace()
                self.silence.bind_machine_turn(agent, 'internal_notification', environ={})
                row = dict(role='assistant', content=text, display_metadata={'fixture': True})
                self.assertTrue(self.silence.mark_silent_final(agent, row, text, successful=True))
                rows = []
                metadata.append_message(rows, row)
                self.assertEqual(rows[-1]['content'], text)
                self.assertEqual(rows[-1]['display_kind'], 'hidden')
                self.assertEqual(rows[-1]['display_metadata'],
                                 {'fixture': True, 'control_marker': 'intentional_silence'})
                self.assertIsInstance(rows[-1]['timestamp'], float)

    def test_human_text_failure_and_tool_rows_stay_visible(self):
        cases = [
            (dict(role='user', content='[SILENT]'), '[SILENT]', True, True),
            (dict(role='assistant', content='[SILENT]'), '[SILENT]', True, False),
            (dict(role='assistant', content='[SILENT]'), '[SILENT]', False, True),
            (dict(role='assistant', content='It says [SILENT].'), 'It says [SILENT].', True, True),
            (dict(role='assistant', content='[SILENT]', tool_calls=[{'id': 'a'}]), '[SILENT]', True, True),
            (dict(role='assistant', content='[SILENT]'), 'Other text', True, True),
        ]
        for row, text, successful, machine in cases:
            with self.subTest(row=row, successful=successful, machine=machine):
                original = copy.deepcopy(row)
                self.assertFalse(self.silence.mark_silent_final(
                    SimpleNamespace(_machine_control_turn=machine), row, text, successful=successful))
                self.assertEqual(row, original)

    def test_child_origin_is_consumed_once_and_human_turn_resets_it(self):
        agent = SimpleNamespace()
        env = {self.silence.MACHINE_TURN_ENV: '1'}
        self.assertEqual(self.silence.bind_machine_turn(agent, None, environ=env), 'internal_notification')
        self.assertTrue(agent._machine_control_turn)
        self.assertEqual(env, {})
        self.assertIsNone(self.silence.bind_machine_turn(agent, None, environ=env))
        self.assertFalse(agent._machine_control_turn)
        self.assertEqual(self.silence.bind_machine_turn(agent, 'user',
                         environ={self.silence.MACHINE_TURN_ENV: '1'}), 'user')
        self.assertFalse(agent._machine_control_turn)

    def completion(self, *, machine=True, text='[SILENT]', status='complete'):
        stub('agent.context_compressor', _DB_PERSISTED_MARKER='_db_persisted')
        prompt = hermes_module('tui_gateway.prompt_turn')
        agent = SimpleNamespace(_session_title_hint='Fixture chat', _machine_control_turn=machine,
                                _persist_user_message_idx=0,
                                context_compressor=SimpleNamespace(compression_count=0))
        rows = [dict(role='user', content='machine wake', _row_id=1, _db_persisted=True),
                dict(role='assistant', content=text, _row_id=2, _db_persisted=True)]
        st = prompt._TurnRun(agent=agent, one_turn_restore=None, terminal_callback=None, receipt_committed=False,
                            history=[], compression_count=0, result={'messages': rows, 'final_response': text})
        if status == 'error':
            st.result.update(failed=True, error='fixture failure')
        elif status == 'interrupted':
            st.result['interrupted'] = True
        server = SimpleNamespace(
            __builtins__=vars(builtins),
            _get_usage=lambda _: {}, render_message=lambda *_: None,
            _clear_inflight_turn=lambda _: None, _fail_inflight_turn=lambda *a, **kw: None,
            _turn_failure_detail=lambda *a: '', INTERRUPT_WAITING_FOR_MODEL_PREFIX='Waiting for response',
        )
        prompt.register(server)
        session = dict(agent=agent, session_key='fixture-session', history_lock=contextlib.nullcontext())
        return server._complete_turn_payload(session, st, None, 80)[0]

    def test_completion_keeps_raw_row_identity_when_display_text_is_empty(self):
        payload = self.completion()
        self.assertEqual(payload['text'], '')
        self.assertIs(payload['intentional_silence'], True)
        self.assertEqual(payload['persisted_turn'], dict(row_ids=[1, 2], user_row_id=1,
                         final_assistant_row_id=2, complete=True))

    def test_completion_never_marks_human_replies_failures_or_interruptions_silent(self):
        cases = [(False, '[SILENT]', 'complete'), (True, 'Useful reply', 'complete'),
                 (True, '[SILENT]', 'error'), (True, '[SILENT]', 'interrupted')]
        for machine, text, status in cases:
            with self.subTest(machine=machine, text=text, status=status):
                payload = self.completion(machine=machine, text=text, status=status)
                self.assertNotIn('intentional_silence', payload)
                self.assertEqual(payload['text'], text)

    def test_resume_keeps_quiet_turn_boundary_without_exposing_other_hidden_rows(self):
        stub('agent.prompt_builder', STEER_DISPLAY_KIND='steer')
        history_module = hermes_module('tui_gateway.session_history')
        server = SimpleNamespace(
            __builtins__=vars(builtins),
            project_compaction_message_for_display=lambda row: row,
            describe_skill_invocation=lambda *a, **kw: None,
            _user_image_display_text=lambda _: None,
        )
        history_module.register(server)
        rows = [
            dict(role='user', content='machine wake', display_kind='internal_notification', _row_id=1),
            dict(role='assistant', content='NO_REPLY', display_kind='hidden', _row_id=2, timestamp=101.0,
                 display_metadata={'control_marker': 'intentional_silence'}),
            dict(role='user', content='NO_REPLY', _row_id=3),
            dict(role='assistant', content='NO_REPLY', _row_id=4),
            dict(role='assistant', content='hidden scaffold', display_kind='hidden'),
            dict(role='assistant', content='hidden malformed', display_kind='hidden',
                 display_metadata='intentional_silence'),
            dict(role='user', content='hidden input', display_kind='hidden',
                 display_metadata={'control_marker': 'intentional_silence'}),
        ]
        original = copy.deepcopy(rows)
        resumed = server._history_to_messages(rows, profile_home=self.home)
        self.assertEqual([row['row_id'] for row in resumed], [1, 2, 3, 4])
        self.assertEqual(resumed[0]['display_kind'], 'internal_notification')
        self.assertEqual(resumed[1]['display_kind'], 'hidden')
        self.assertEqual(resumed[1]['text'], 'NO_REPLY')
        self.assertEqual(resumed[1]['timestamp'], 101.0)
        self.assertEqual(resumed[1]['display_metadata'], {'control_marker': 'intentional_silence'})
        self.assertNotIn('display_kind', resumed[2])
        self.assertNotIn('display_kind', resumed[3])
        self.assertEqual(rows, original)

    def test_database_preserves_hidden_marker_and_typed_metadata(self):
        # Compression is unused by these plain rows. Its provider imports are
        # replaced while the actual SessionDB schema and message IO run below.
        stub('agent.context_compressor', _DB_PERSISTED_MARKER='_db_persisted',
             LEGACY_SUMMARY_PREFIX='old summary', SUMMARY_PREFIX='summary',
             _MERGED_PRIOR_CONTEXT_HEADER='prior', _MERGED_SUMMARY_DELIMITER='delimiter',
             _SUMMARY_END_MARKER='end summary', MODEL_ONLY_DISPLAY_METADATA_KEY='model_only',
             _is_checkpoint_item=lambda _: False, _newest_checkpoint_carrier=lambda *a: -1,
             split_user_originated_turn=lambda _: None, user_originated_turn_view=lambda value: value)
        database = hermes_module('hermes_state')
        agent = SimpleNamespace(_machine_control_turn=True)
        row = dict(role='assistant', content='NO_REPLY', timestamp=100.0)
        self.silence.mark_silent_final(agent, row, 'NO_REPLY', successful=True)
        with contextlib.closing(database.SessionDB(db_path=self.home / 'fixture.db')) as db:
            db.create_session('fixture', source='cli')
            db.replace_messages('fixture', [row])
            stored = db.get_messages('fixture')
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]['content'], 'NO_REPLY')
        self.assertEqual(stored[0]['display_kind'], 'hidden')
        self.assertEqual(stored[0]['display_metadata'], {'control_marker': 'intentional_silence'})

    def finalizer(self):
        stub('agent.context_compressor', _DB_PERSISTED_MARKER='_db_persisted')
        def loop_constant(name):
            if name.startswith('_') and name[1:].isupper():
                return ''
            raise AttributeError(name)
        stub('agent.conversation_loop', logger=logging.getLogger('fixture'),
             _join_truncated_parts=lambda parts: ''.join(text for text, _ in parts),
             _notify_context_engine_turn_complete=lambda *a, **kw: None, __getattr__=loop_constant)
        return hermes_module('agent.turn_finalizer')

    def test_final_response_is_hidden_before_the_first_flush(self):
        finalizer = self.finalizer()
        final = hermes_module('agent.turn_final_response')
        runtime = hermes_module('agent.agent_runtime_helpers')
        flushed = []
        agent = SimpleNamespace(_machine_control_turn=True, quiet_mode=True, valid_tool_names=[],
            _stall_guards=False, _interrupt_requested=False,
            _has_content_after_think_block=lambda text: bool(text),
            _emit_pending_fallback_notice=lambda: None, _clear_status_buffer=lambda: None,
            _strip_think_blocks=lambda text: text,
            _build_assistant_message=lambda message, reason: dict(role='assistant', content=message.content),
            _flush_messages_to_session_db=lambda rows, history: flushed.extend(copy.deepcopy(rows)))
        gate = SimpleNamespace(continue_turn=False, pending_verification_response=None,
                               pending_verification_response_previewed=False)
        kwargs = dict.fromkeys(inspect.signature(final.finish_text_response).parameters)
        kwargs.pop('agent')
        kwargs.update(assistant_message=SimpleNamespace(content='[SILENT]', tool_calls=[]),
            finish_reason='stop', messages=[], api_messages=[], conversation_history=[], api_call_count=1,
            user_message='machine wake', active_system_prompt='', _turn_exit_reason='',
            _preflight_compression_blocked=False, truncated_response_parts=[], length_continue_retries=0,
            _pending_verification_response_previewed=False, effective_task_id='fixture')
        with patch.object(runtime, 'intent_ack_continuation_mode', return_value='off'), \
             patch.object(final, 'apply_stop_gates', return_value=gate), \
             patch.object(finalizer, 'apply_llm_output_transform', side_effect=lambda a, r, **kw: (r, False, None)):
            verdict = final.finish_text_response(agent, **kwargs)
        self.assertEqual(verdict.action, 'break')
        self.assertEqual(flushed[-1]['content'], '[SILENT]')
        self.assertEqual(flushed[-1]['display_kind'], 'hidden')

    def test_finalizer_fallback_hides_success_but_preserves_failure(self):
        finalizer = self.finalizer()
        fixture = hermes_module('tests.agent.test_turn_finalizer_final_response_persistence')
        stub('agent.turn_context', start_deferred_title_upgrade=lambda _: None)
        stub('hermes_cli.observability.shared_metrics_harness', finish_turn=lambda *a, **kw: None)
        for failed in (False, True):
            with self.subTest(failed=failed):
                agent = fixture.FakeAgent()
                agent._machine_control_turn = True
                with patch.object(finalizer, '_invoke_hook_safely', return_value=[]), \
                     patch.object(finalizer, '_micro_compact_after_turn', return_value=None):
                    finalizer.finalize_turn(agent, final_response='[SILENT]', api_call_count=1,
                        interrupted=False, failed=failed, messages=[dict(role='user', content='machine wake')],
                        conversation_history=[], effective_task_id='fixture', turn_id='fixture',
                        user_message='machine wake', original_user_message='machine wake',
                        _should_review_memory=False, _turn_exit_reason='fallback_prior_turn_content')
                self.assertEqual(agent.persisted_messages[-1]['content'], '[SILENT]')
                self.assertEqual(agent.persisted_messages[-1].get('display_kind'), None if failed else 'hidden')

    def delivery(self):
        stub('cron.scheduler', tick=lambda: None)
        for name in ('cron.scheduler_delivery_origin', 'cron.scheduler_preflight', 'cron.scheduler_script'):
            stub(name)
        stub('hermes_cli.config_effective', load_user_config_effective=lambda _: {})
        return hermes_module('cron.scheduler_delivery'), hermes_module('tools.bot_live_delivery')

    def test_cron_live_delivery_keeps_machine_origin_in_the_durable_envelope(self):
        delivery, mailbox = self.delivery()
        job = dict(id='fixture-job', name='Fixture', execution_id='fixture-run')
        with patch.object(mailbox, 'find_canonical_live_owner', return_value=self.owner()), \
             patch.object(delivery, '_run_bot_chat_turn', side_effect=AssertionError('No child may start')):
            result = delivery._deliver_to_bot_chat(job, 'Fixture result', '')
        self.assertIn('queued', result)
        receipt_id = job['_bot_chat_delivery_receipts']['bot-chat:(own)']['delivery_id']
        self.assertIs(mailbox.read_delivery_result(self.home, receipt_id)['machine_turn'], True)

    def test_cron_child_origin_is_limited_to_that_child_environment(self):
        delivery, mailbox = self.delivery()
        stub('tools.environments.local', served_profile_child_env=lambda *a, **kw: {})
        captured = {}
        def run(argv, env, report, timeout):
            captured.update(env)
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(mailbox, 'find_canonical_live_owner', return_value=None), \
             patch.object(mailbox, 'find_canonical_owner', return_value=None), \
             patch.object(delivery, '_get_bot_chat_delivery_timeout', return_value=30), \
             patch.object(delivery, '_run_bot_chat_turn', side_effect=run):
            result = delivery._deliver_to_bot_chat(dict(id='fixture-job', name='Fixture'), 'Fixture result', '')
        self.assertIsNone(result)
        self.assertEqual(captured[self.silence.MACHINE_TURN_ENV], '1')
        self.assertNotIn(self.silence.MACHINE_TURN_ENV, os.environ)

    def test_mailbox_origin_is_durable_and_cannot_change_for_an_existing_receipt(self):
        mailbox = hermes_module('tools.bot_live_delivery')
        owner = self.owner()
        human = mailbox.deliver_to_live_owner(self.home, owner, '[SILENT]')
        self.assertNotIn('machine_turn', human)
        with self.assertRaises(ValueError):
            mailbox.deliver_to_live_owner(self.home, owner, '[SILENT]', delivery_id=human['id'], machine_turn=True)
        machine = mailbox.deliver_to_live_owner(self.home, owner, 'machine wake', machine_turn=True)
        self.assertIs(mailbox.read_delivery_result(self.home, machine['id'])['machine_turn'], True)
        with self.assertRaises(ValueError):
            mailbox.deliver_to_live_owner(self.home, owner, 'machine wake', delivery_id=machine['id'])

    def test_mailbox_consumer_passes_origin_only_from_the_typed_receipt(self):
        mailbox = hermes_module('tools.bot_live_delivery')
        notifications = hermes_module('tui_gateway.session_notifications')
        lifecycle = hermes_module('tui_gateway.session_lifecycle')
        owner, seen = self.owner(), []
        def submit(rid, sid, session, text, **kwargs):
            seen.append(kwargs.get('display_kind'))
            kwargs['terminal_callback']({'status': 'settled', 'text': ''})
            return True
        server = SimpleNamespace(
            __builtins__=vars(builtins),
            _session_home=lambda _: self.home,
            _session_turn_admission=lifecycle._session_turn_admission,
            _run_prompt_submit=submit, _notif_release_turn=lambda session: session.update(running=False),
        )
        notifications.register(server)
        with patch.object(mailbox, 'find_canonical_live_owner', return_value=owner):
            for machine in (True, False):
                receipt = mailbox.deliver_to_live_owner(self.home, owner, 'fixture', machine_turn=machine)
                session = dict(history_lock=threading.RLock(), agent=object(), session_key='fixture-session',
                               active_session_lease=SimpleNamespace(lease_id='fixture-lease', released=False))
                self.assertTrue(server._poll_bot_live_delivery_once('fixture-live', session))
                self.assertEqual(mailbox.read_delivery_result(self.home, receipt['id'])['status'], 'settled')
        self.assertEqual(seen, ['internal_notification', None])


if __name__ == '__main__':
    unittest.main()
