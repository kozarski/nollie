"""Quiet Bot Chat check-ins, proved against the pinned Hermes with no Nollie changes.

Hermes 0.23 admits every Bot Chat delivery (a schedule's report, another bot's message) through
the profile gateway as an automated turn, and its own silence rules hide a bare control marker
only on such turns. These tests run the real delivery, admission, reply-shaping, relay-receipt,
storage and history code. Only provider setup and unused config readers are replaced at import
boundaries.
"""
import asyncio
import builtins
import contextlib
import copy
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

from support import hermes_module, hermes_source

MARKERS = ('[SILENT]', 'NO_REPLY', ' *NO_REPLY* ', 'SILENT')


def stub(name, **values):
    module = ModuleType(name)
    vars(module).update(values)
    sys.modules[name] = module
    return module


class BotChatSilenceTests(unittest.TestCase):
    def setUp(self):
        self.home = self.enterContext(hermes_source())
        # Mailbox and gateway file IO never parse YAML or read a .env file here.
        stub('hermes_yaml')
        stub('dotenv', load_dotenv=lambda *a, **kw: False, dotenv_values=lambda *a, **kw: {})
        self.filters = hermes_module('gateway.response_filters')

    def owner(self):
        return dict(profile_home=str(self.home.resolve()), session_id='fixture-session',
                    live_session_id='fixture-session', lease_id='fixture-lease')

    # A schedule's report reaches the gateway as a trusted producer message.

    def deliver_from_schedule(self, for_failure=False):
        stub('hermes_cli.config_effective', load_user_config_effective=lambda _: {})
        delivery = hermes_module('cron.scheduler_delivery')
        mailbox = hermes_module('tools.bot_live_delivery')
        sent = []

        def authority(home, params):
            sent.append(params)
            return dict(params, status='settled', delivery_id=params['id'])
        job = dict(id='fixture-job', name='Fixture', execution_id='fixture-run')
        with patch.object(mailbox, 'find_canonical_live_owner', return_value=self.owner()), \
             patch.object(mailbox, 'authority_delivery', side_effect=authority):
            result = delivery._deliver_to_bot_chat(job, 'Fixture result', '', for_failure=for_failure)
        return result, sent, job

    def test_schedule_report_goes_to_the_gateway_as_a_producer_message(self):
        result, sent, job = self.deliver_from_schedule()
        self.assertIsNone(result)
        self.assertEqual(len(sent), 1)
        self.assertIn('Fixture result', sent[0]['message'])
        # No author: a producer report, never a person or a bot speaking in the chat.
        self.assertNotIn('author', sent[0])
        self.assertNotIn('notification_category', sent[0])
        self.assertEqual(job['_bot_chat_delivery_receipts']['bot-chat:(own)']['status'], 'settled')

    def test_schedule_failure_keeps_its_diagnostic_category(self):
        result, sent, _ = self.deliver_from_schedule(for_failure=True)
        self.assertIsNone(result)
        self.assertEqual(sent[0]['notification_category'], 'diagnostic')

    def admit(self, **kwargs):
        bot = hermes_module('gateway.session_bot')
        admitted = []

        async def admit_automation(adapter, event, identity):
            admitted.append((event, identity))
            return SimpleNamespace(admission_id='fixture-admission')

        async def write_receipt(home, record, expect=None):
            return True

        async def published(authority, home, record):
            return record

        async def no_retry(*args):
            return None
        authority = SimpleNamespace(admit_automation=admit_automation,
                                    runner=SimpleNamespace(_adapter_for_source=lambda source: None))
        actor = SimpleNamespace(subject='fixture-principal', capabilities=frozenset())
        live = SimpleNamespace(source=SimpleNamespace(platform='local', chat_id='fixture'), route='fixture-route')
        entry = SimpleNamespace(session_id='fixture-session')
        with patch.object(bot, 'write_receipt', write_receipt), \
             patch.object(bot, '_result', return_value={'status': 'settled'}), \
             patch.object(bot, '_maybe_retry', no_retry), patch.object(bot, '_publish_result', published):
            record = asyncio.run(bot._admit(authority, actor, self.home, self.home, 'a' * 32, 'machine wake',
                                            SimpleNamespace(session_id='fixture-session'), live, entry, **kwargs))
        self.assertEqual(len(admitted), 1)
        return admitted[0][0], record

    def test_every_delivery_is_admitted_as_an_automated_turn(self):
        for kwargs in ({}, {'notification_category': 'diagnostic'},
                       {'author': {'profile': 'fixture-peer', 'display_name': 'Peer'}}):
            with self.subTest(kwargs=kwargs):
                event, record = self.admit(**kwargs)
                self.assertIs(event.internal, True)
                self.assertEqual(event.message_id, 'bot:' + 'a' * 32)
                self.assertEqual(record['message'], 'machine wake')
                # The stored user row gets the machinery kind, the only kind that may end in silence.
                self.assertEqual(self.filters.display_kind_for_event(event), 'internal_notification')
                category = kwargs.get('notification_category')
                self.assertEqual(event.metadata.get('notification_category'), category)

    def test_a_person_typing_is_never_an_automated_turn(self):
        event_module = hermes_module('gateway.platforms.event')
        typed = event_module.MessageEvent(text='[SILENT]', source=SimpleNamespace(platform='local'))
        self.assertIsNone(self.filters.display_kind_for_event(typed))
        self.assertFalse(self.filters.is_machinery_display_kind(None))

    # The gateway's reply shaping decides what is delivered.

    def shape(self, response, *, kind='internal_notification', **result):
        persistence = hermes_module('gateway.run_turn_persistence')
        loaders = hermes_module('gateway.run_config_loaders')

        class Runner(persistence.GatewayTurnPersistenceMixin, loaders.GatewayConfigLoadersMixin):
            def _room_allow_silence(self, source):
                return None  # no room has opted in

            def _delivery_adapter_for(self, source):
                return None

            def _should_send_voice_reply(self, *args, **kwargs):
                return False
        runner = Runner()
        messages = [dict(role='user', content='machine wake'), dict(role='assistant', content=response)]
        original = copy.deepcopy(messages)
        agent_result = dict(final_response=response, messages=messages, api_calls=1, **result)
        source = SimpleNamespace(platform='local', chat_id='fixture', is_bot=False)
        shaped, silent, kept = asyncio.run(runner._hmwa_shape_agent_response(
            agent_result, source, [], SimpleNamespace(session_id='fixture-session'), None,
            'fixture', 1, 'fixture-session', 'local', 0.0, persist_user_display_kind=kind))
        delivered = asyncio.run(runner._hmwa_deliver_turn_response(
            SimpleNamespace(metadata={}), source, SimpleNamespace(session_id='fixture-session'), None, 1,
            agent_result, kept, shaped, '', silent))
        self.assertEqual(kept, original)  # the raw rows go to storage unchanged
        return silent, delivered

    def test_successful_automated_marker_is_delivered_as_nothing(self):
        for text in MARKERS:
            with self.subTest(text=text):
                self.assertEqual(self.shape(text), (True, ''))

    def test_human_turn_never_ends_in_silence(self):
        silent, delivered = self.shape('[SILENT]', kind=None)
        self.assertFalse(silent)
        self.assertTrue(delivered.strip())
        self.assertNotEqual(delivered.strip(), '[SILENT]')

    def test_useful_reply_stays_visible(self):
        self.assertEqual(self.shape('It says [SILENT].'), (False, 'It says [SILENT].'))
        self.assertEqual(self.shape('Two new invoices.\n\n[SILENT]'), (False, 'Two new invoices.'))

    def test_failed_turn_stays_visible(self):
        silent, delivered = self.shape('[SILENT]', failed=True, error='fixture failure')
        self.assertFalse(silent)
        self.assertTrue(delivered.strip())

    # What the sending bot or schedule reads back.

    def outcome(self, reply, outcome='completed', failed=False):
        bot = hermes_module('gateway.session_bot')
        results = hermes_module('gateway.session_results')
        row = dict(status='terminal', outcome=outcome)
        saved = {'result': {'final_response': reply, 'failed': failed}}
        with patch.object(bot, 'get_session_admission', return_value=row), \
             patch.object(results, 'admission_result', return_value=saved):
            return bot._admission_outcome(SimpleNamespace(db=None), 'fixture-admission')

    def test_relay_receipt_is_quiet_only_for_a_settled_marker(self):
        for text in MARKERS:
            with self.subTest(text=text):
                self.assertEqual(self.outcome(text), ('settled', ''))
        self.assertEqual(self.outcome('Two new invoices.'), ('settled', 'Two new invoices.'))
        self.assertEqual(self.outcome('[SILENT]', outcome='failed', failed=True), ('failed', '[SILENT]'))

    # Raw history stays, with the typed row a client needs to hide the pair.

    def test_storage_keeps_the_raw_marker_and_the_automated_prompt_kind(self):
        database = hermes_module('hermes_state')
        rows = [dict(role='user', content='machine wake', display_kind='internal_notification', timestamp=100.0),
                dict(role='assistant', content='NO_REPLY', timestamp=101.0),
                dict(role='user', content='[SILENT]', timestamp=102.0),
                dict(role='assistant', content='Sure, staying quiet.', timestamp=103.0)]
        with contextlib.closing(database.SessionDB(db_path=self.home / 'fixture.db')) as db:
            db.create_session('fixture', source='cli')
            db.replace_messages('fixture', rows)
            stored = db.get_messages('fixture')
        self.assertEqual([row['content'] for row in stored], [row['content'] for row in rows])
        self.assertEqual([row.get('display_kind') for row in stored], ['internal_notification', None, None, None])

    def test_resume_returns_the_raw_pair_with_its_types(self):
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
            dict(role='assistant', content='NO_REPLY', _row_id=2, timestamp=101.0),
            dict(role='user', content='NO_REPLY', _row_id=3),
            dict(role='assistant', content='NO_REPLY', _row_id=4),
            dict(role='assistant', content='hidden scaffold', display_kind='hidden'),
        ]
        original = copy.deepcopy(rows)
        resumed = server._history_to_messages(rows, profile_home=self.home)
        self.assertEqual([row['row_id'] for row in resumed], [1, 2, 3, 4])
        self.assertEqual(resumed[0]['display_kind'], 'internal_notification')
        self.assertEqual(resumed[1]['text'], 'NO_REPLY')
        self.assertEqual(resumed[1]['timestamp'], 101.0)
        # A person's literal marker and the reply to it stay ordinary rows.
        self.assertNotIn('display_kind', resumed[2])
        self.assertNotIn('display_kind', resumed[3])
        self.assertEqual(rows, original)

    # The desktop's own Bot Chat completion.

    def completion(self, *, text='[SILENT]', status='complete', title='Bot Chat'):
        persisted = hermes_module('agent.context_compressor')._DB_PERSISTED_MARKER
        prompt = hermes_module('tui_gateway.prompt_turn')
        agent = SimpleNamespace(_session_title_hint=title, _persist_user_message_idx=0,
                                context_compressor=SimpleNamespace(compression_count=0))
        rows = [dict(role='user', content='machine wake', _row_id=1, **{persisted: True}),
                dict(role='assistant', content=text, _row_id=2, **{persisted: True})]
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

    def test_bot_chat_completion_is_empty_but_keeps_the_raw_row_receipt(self):
        payload = self.completion()
        self.assertEqual(payload['text'], '')
        self.assertEqual(payload['status'], 'complete')
        receipt = payload['persisted_turn']
        self.assertEqual((receipt['row_ids'], receipt['user_row_id'], receipt['final_assistant_row_id'],
                          receipt['complete']), ([1, 2], 1, 2, True))

    def test_bot_chat_completion_keeps_replies_and_failures(self):
        self.assertEqual(self.completion(text='Useful reply')['text'], 'Useful reply')
        for status in ('error', 'interrupted'):
            with self.subTest(status=status):
                self.assertTrue(self.completion(status=status)['text'])
        self.assertEqual(self.completion(title='Fixture chat')['text'], '[SILENT]')


if __name__ == '__main__':
    unittest.main()
