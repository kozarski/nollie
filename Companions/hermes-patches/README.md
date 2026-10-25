# Hermes add-ons and remaining patches

| Patch | New home | How it is tested |
| :--- | :--- | :--- |
| Cron fail-closed precheck | Watch binding stays in `nollie-workflow/hermes_support/ollie_cron_followups.py`. The nine-line scheduler guard remains a checked overlay. | `nollie-workflow/tests/test_native_cron.py` imports the real scheduler and job store, tests missing and failed checks, wake gates, binding and pause. |
| Kanban machine prompts | The one-line desktop notification origin tag remains a checked overlay. | `tests/test_board_notifications.py` runs the real poller, submission and warning policy with queued, stopped and failed turns. |
| Kanban timeout evidence | The small desktop timeout formatter remains a checked overlay. | `tests/test_board_notifications.py` checks recorded limits, missing evidence, changed settings and unchanged events. |
| Silent Bot Chat | The trusted-origin, stored-row, receipt and resume changes remain a checked overlay. | `tests/test_bot_chat_silence.py` imports the real mailbox, turn, history and storage code; checks quiet replies, raw history, human messages and failures. |
| Board read helper copied into Hermes | `nollie-workflow/hermes_support/nollie_board_observer.py`, imported from the add-on. | `nollie-workflow/tests/test_native_board.py` reads a real Hermes fixture through the add-on and checks it stays unchanged. Both installer paths check helper placement. |
| Cron binding helper copied into Hermes | `nollie-workflow/hermes_support/ollie_cron_followups.py`, imported from the add-on. | Real Hermes job-store tests and both installer paths check binding and source preservation. |

Nollie's installers no longer copy workflow helpers into Hermes source. They live
with the add-on and travel in its checked Setup Kit. Existing helper copies in a
separate Hermes installation are left alone.

Hermes v0.22.2 still needs the four small source exceptions above. A fully unchanged
Hermes install cannot preserve this behavior with its current extension points.
The managed setup applies only these reviewed exceptions, after checking the exact
source hashes. It never applies a patch to a running or independently installed copy.

## Why the exceptions remain

- Cron has no hook before `_prepare_job_prompt` creates the prompt and starts the
  agent. `pre_tool_call` runs too late to stop a failed watch check from starting
  an agent. The guard remains opt-in through `precheck_fail_closed: true`.
- The desktop Board poller has no hook to change its prompt origin or timeout
  text. Kanban hooks observe events; their return values cannot change these
  notifications. The messaging gateway's hooks and notification switch do not
  cover this desktop path. Plugin message injection cannot set the trusted
  machine tag or diagnostic metadata, so it cannot replace that path either.
- Quiet Bot Chat needs trusted origin at cron delivery, metadata before the first
  stored assistant row, the original completion receipt and typed rows on resume.
  `transform_llm_output` changes text, which would lose the raw marker.
  `post_llm_call` runs after the first flush. Neither supplies the missing
  persistence and desktop notification hooks.

These checks were made against the pinned code in `hermes_cli/plugins.py`,
`cron/scheduler.py`, `cron/scheduler_delivery.py`, `agent/turn_final_response.py`
and the desktop `tui_gateway` modules. No add-on replaces Hermes functions at
runtime to imitate a missing hook. Recheck these gaps when the Hermes pin changes.

The quiet-turn patch preserves raw history and receipt identity. Only successful
machine control replies are hidden. Human text, useful replies and failures stay
visible. Timeout wording uses the recorded event, never today's task settings,
and does not promise a retry.

## Build and check offline

The single portable manifest is
[`overlay.json`](../../Services/Runtime/HermesOverlay/overlay.json). It records the
pinned release, remaining gaps and every file's before and after SHA-256. The old
personal deployment manifests and standalone test runners have been retired.

From the repository root, using a read-only checkout of the pinned commit:

```sh
python3 Tools/dev/hermes-overlay.py --source ../hermes-v0.22.2 --check
```

Omit `--check` to rebuild the reviewed overlay. This copies only the affected
source files into a temporary folder, checks them against the pinned Git commit,
and applies the four patches there. A changed source file stops the build.
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

The integration fixtures find `../hermes-v0.22.2` beside this worktree. Set
`NOLLIE_HERMES_SOURCE` to use another checkout of that pin. They import complete
Hermes modules by path, with the reviewed overlay selected by an import finder.
They check the original and replacement hashes, use empty temporary homes, block
network connections and do not write bytecode into Hermes. Optional provider and
configuration dependencies are isolated at import boundaries. No packages are
installed. The wider workflow suite also has optional web dependencies and local
socket fixtures; report any unavailable dependencies or sandbox limits separately.
