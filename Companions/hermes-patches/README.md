# Hermes add-ons and remaining patches

| Patch | New home | How it is tested |
| :--- | :--- | :--- |
| Cron fail-closed precheck | Watch binding stays in `nollie-workflow/hermes_support/ollie_cron_followups.py`. The nine-line scheduler guard remains a checked overlay. | `nollie-workflow/tests/test_native_cron.py` imports the real scheduler and job store, tests missing and failed checks, wake gates, binding and pause. |
| Kanban machine prompts | The one-line desktop notification origin tag remains a checked overlay. | `tests/test_board_notifications.py` runs the real poller, submission and warning policy with queued, stopped and failed turns. |
| Kanban timeout evidence | The small desktop timeout formatter remains a checked overlay. | `tests/test_board_notifications.py` checks recorded limits, missing evidence, changed settings and unchanged events. |
| Silent Bot Chat | No longer needed. Hermes 0.23.1 admits every Bot Chat delivery as an automated turn and keeps a bare control reply quiet itself. | `tests/test_bot_chat_silence.py` runs the real, unchanged delivery, admission, reply shaping, relay receipt, storage, history and completion code; checks quiet check-ins, raw history, human messages, useful replies and failures. |
| Board read helper copied into Hermes | `nollie-workflow/hermes_support/nollie_board_observer.py`, imported from the add-on. | `nollie-workflow/tests/test_native_board.py` reads a real Hermes fixture through the add-on and checks it stays unchanged. Both installer paths check helper placement. |
| Cron binding helper copied into Hermes | `nollie-workflow/hermes_support/ollie_cron_followups.py`, imported from the add-on. | Real Hermes job-store tests and both installer paths check binding and source preservation. |

Nollie's installers no longer copy workflow helpers into Hermes source. They live
with the add-on and travel in its checked Setup Kit. Existing helper copies in a
separate Hermes installation are left alone.

Hermes v0.23.1 still needs three small source exceptions: the cron guard and the two
Board notification changes. A fully unchanged Hermes install cannot preserve this behavior
with its current extension points. The managed setup applies only these reviewed exceptions,
after checking the exact source hashes. It never applies a patch to a running or
independently installed copy.

## Why the exceptions remain

- Cron still has no hook before `_prepare_job_prompt` runs the pre-check and
  `run_job` builds the agent (`cron/scheduler.py:2236`, `:2575`, `:2484`). Nothing
  under `cron/` calls a plugin hook. The new blocking `pre_llm_call` fires inside a
  turn, after the agent and its session exist (`agent/conversation_loop.py:1618`),
  and it never sees the pre-check's result. `ctx.post_message` refuses to run from
  cron (`hermes_cli/plugin_messages.py:5`), and `on_session_open` fires only when a
  client opens a local chat (`gateway/session_open.py:88`). So a hook cannot keep a failed watch check from starting an agent.
  The guard remains opt-in through `precheck_fail_closed: true`.
- The desktop Board poller still has no hook for its prompt origin or timeout text
  (`tui_gateway/session_notifications.py:421`, `:603`). Kanban hooks observe events
  and their return values are ignored (`hermes_cli/plugins.py:162`, `:167`).
  `ctx.post_message` only posts text into a running session, so it cannot start
  the turn with the trusted machine tag or diagnostic metadata. `hold_stream`
  applies only to `transform_llm_output` replies (`hermes_cli/plugins_dispatch.py:70`).
  The new session, compaction and curator hooks are observers on other paths.

## Why quiet Bot Chat needs no patch now

Bot Chat delivery moved into the profile gateway. Each delivery, from a schedule
or another bot, is admitted as an automated message (`gateway/session_bot.py:960`),
which stores its prompt row as `internal_notification`
(`gateway/response_filters.py:187`, `gateway/run_turn_prepare.py:756`). Only that
kind may end in silence: a successful bare marker is delivered as nothing while
the raw turn stays stored (`gateway/run_turn_persistence.py:121`, `:684`), a
person's turn gets a visible reply instead, and failures and useful replies are
never silenced (`gateway/response_filters.py:169`). The sender's receipt hides the
marker the same way (`gateway/session_bot.py:434`), and the desktop's Bot Chat
completion keeps the raw row receipt (`tui_gateway/prompt_turn.py:946`). Nollie's
chat view hides the automated prompt and its marker reply from the typed rows.

These checks were made against the pinned code in `hermes_cli/plugins.py`,
`hermes_cli/plugins_dispatch.py`, `cron/scheduler.py`, the `gateway` Bot Chat
modules and the desktop `tui_gateway` modules. No add-on replaces Hermes functions
at runtime to imitate a missing hook. Recheck these gaps when the Hermes pin changes.

Timeout wording uses the recorded event, never today's task settings, and does not
promise a retry.

## Build and check offline

The single portable manifest is
[`overlay.json`](../../Services/Runtime/HermesOverlay/overlay.json). It records the
pinned release, remaining gaps and every file's before and after SHA-256. The old
personal deployment manifests and standalone test runners have been retired.

From the repository root, using a read-only checkout of the pinned commit:

```sh
python3 Tools/dev/hermes-overlay.py --source ../hermes-v0.23.1 --check
```

Omit `--check` to rebuild the reviewed overlay. This copies only the affected
source files into a temporary folder, checks them against the pinned Git commit,
and applies the three patches there. A changed source file stops the build.
Update `NativeSetupPlan.hermesOverlayDigest` after rebuilding. During managed
setup, the app checks that manifest digest, every original file and every result
before publishing the prepared Hermes tree. The upstream license stays included.

Run discovery from each test folder:

```sh
(cd Companions/hermes-patches/tests && python3 -m unittest discover -p 'test*.py')
(cd Companions/nollie-workflow/tests && python3 -m unittest discover -p 'test*.py')
(cd Tools/dev && python3 -m unittest discover -p 'test*.py')
(cd Tools/runtime-helper && python3 -m unittest discover -p 'test*.py')
```

The integration fixtures find `../hermes-v0.23.1` beside this worktree. Set
`NOLLIE_HERMES_SOURCE` to use another checkout of that pin. They import complete
Hermes modules by path, with the reviewed overlay selected by an import finder.
They check the original and replacement hashes, use empty temporary homes, block
network connections and do not write bytecode into Hermes. Optional provider and
configuration dependencies are isolated at import boundaries. No packages are
installed. The wider workflow suite also has optional web dependencies and local
socket fixtures; report any unavailable dependencies or sandbox limits separately.
