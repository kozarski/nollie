"""Explicit lifecycle tools backed by native cron jobs, never another dispatcher."""
from pathlib import Path
import json
import os
import tempfile

from .followup_policy import Followups
from .hermes_adapter import BoardSource, default_scope
from .workflow_core import read_state


class NativeJobs:
    def __init__(self, home):
        self.home = home

    def get(self, job_id):
        from cron.jobs import get_job
        with default_scope(self.home):
            return get_job(job_id)

    def bind_gate(self, job_id, expected, script):
        from .hermes_support.ollie_cron_followups import bind_gate
        with default_scope(self.home):
            return bind_gate(job_id, expected, script, self.route_signature)

    @staticmethod
    def route_signature(job):
        from .followup_policy import route_signature
        return route_signature(job)

    def pause_gate(self, job_id, expected, script, reason):
        from .hermes_support.ollie_cron_followups import pause_gate
        with default_scope(self.home):
            return pause_gate(job_id, expected, script, self.route_signature, reason)


def manager(home):
    source = BoardSource(home)
    return Followups(Path(home) / "nollie-workflow", NativeJobs(home), source.task)


def install_gate(home, key):
    """One fixed wrapper per task, inside Hermes's permitted script directory."""
    root = Path(home) / "scripts"
    target = root / ("nollie-followup-" + key + ".py")
    if root.is_symlink() or target.is_symlink():
        raise ValueError("linked script destination")
    body = (
        "import json, runpy\nfrom pathlib import Path\n"
        "try:\n"
        "    runpy.run_path(str(Path(__file__).resolve().parents[1] / 'plugins' / 'nollie-workflow' / 'followup_gate.py'), "
        "init_globals={'WATCH_KEY': " + repr(key) + "}, run_name='__main__')\n"
        "except Exception:\n    print(json.dumps({'wakeAgent': False, 'reason': 'followup_unavailable'}))\n"
    )
    if target.exists():
        if target.read_text() != body:
            raise ValueError("existing gate differs; preserve it for review")
        return target.name
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".followup-", dir=root)
    try:
        with os.fdopen(fd, "w") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return target.name


DESCRIPTION = (
    "Keep an authorized task's checkpoint or explicit watch durable. A one-off search is not a watch. "
    "bind_watch binds ONE existing paused daily cron job with explicit model/provider pins; it does not resume it. "
    "Use native cron tools to create/resume the job after checking its model route and delivery costs. "
    "The timezone must equal the profile scheduler timezone. record_check stores comparable verified facts; finish_check finalizes all comparisons and "
    "returns [SILENT] for unchanged results. A completed check does not finish a watch. stop closes its gate and "
    "pauses only its bound job. checkpoint saves verified result identities and remaining work; it never unblocks "
    "a task, resets limits or schedules a continuation. Preserve loop, privacy and approval boundaries."
)
SCHEMA = {"name": "nollie_followup", "description": DESCRIPTION, "parameters": {
    "type": "object", "additionalProperties": False,
    "properties": {
        "action": {"type": "string", "enum": ["status", "bind_watch", "checkpoint", "record_check", "finish_check", "stop"]},
        "board": {"type": "string"}, "task_id": {"type": "string"},
        "details": {"type": "object", "description":
            "bind_watch: job_id, request (explicit user request), constraints, spec {timezone, anchor_date YYYY-MM-DD, "
            "stop_date YYYY-MM-DD exclusive, every_days, at HH:MM}. checkpoint: run_id, evidence_ids (actual tool/result "
            "identities, not paraphrases), findings, remaining, next_action. record_check: cycle from gate, comparison_key "
            "(same variant/fare basis), facts (exclude check timestamps), sources. Finish all comparisons then call finish_check with cycle; never finalize a failed check. stop: reason from user completion/cancellation or deadline."}
    }, "required": ["action", "board", "task_id", "details"]}}


def handle(home, args):
    from hermes_cli.profiles import get_active_profile_name
    from hermes_time import get_timezone
    try:
        if get_active_profile_name() != "default" or not read_state(Path(home) / "nollie-workflow")["enabled"]:
            return json.dumps({"ok": False, "error": "Follow-through is not enabled in this profile."})
        action, board, task_id, details = (args[k] for k in ("action", "board", "task_id", "details"))
        if not isinstance(details, dict):
            raise ValueError("invalid details")
        api = manager(home)
        if action == "bind_watch":
            if details["spec"]["timezone"] != str(get_timezone()):
                raise ValueError("watch timezone differs from the scheduler")
            from .hermes_support.ollie_cron_followups import ready
            if not ready():
                return json.dumps({"ok": False, "error": "This Hermes needs the fail-closed pre-check support before a watch can be bound."})
            # Verify ownership before creating even the harmless task-specific gate.
            api._task(board, task_id)
            details = dict(details, script=install_gate(home, api.key(board, task_id)))
        if action not in ("status", "bind_watch", "checkpoint", "record_check", "finish_check", "stop"):
            raise ValueError("unknown action")
        result = getattr(api, action)(board, task_id, **details)
        return json.dumps({"ok": True, **result}, allow_nan=False)
    except (ValueError, TypeError, KeyError):
        return json.dumps({"ok": False, "error": "The task, evidence, cadence or native job did not pass validation. No continuation was started."})
    except Exception:
        return json.dumps({"ok": False, "error": "Follow-through could not confirm this change. Inspect its status before retrying."})


def register(ctx, home):
    ctx.register_tool(name="nollie_followup", toolset="kanban", schema=SCHEMA,
                      handler=lambda args, **_: handle(home, args), description=DESCRIPTION)
