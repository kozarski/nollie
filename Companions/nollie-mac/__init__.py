"""Nollie Mac: the Hermes side of letting a bot use apps on this Mac.

Hermes passes an MCP server no session context, so this small plugin hook does two things for
every `mcp__nollie_mac__*` call before it runs:

- refuses it outright in a scheduled (cron), single-query or other unattended run, where nobody
  could answer the approval card on the Mac;
- stamps the call with the chat it came from (`_nollie`), replacing anything the model wrote there.

The MCP server (server.py) refuses any call without that stamp. The stamp alone proves nothing
(a model could write one where this hook isn't loaded), so Nollie also asks Hermes about the
session before any card shows, and asks the person on the Mac before anything starts.
"""

PREFIX = "mcp__nollie_mac__"
UNATTENDED = ("Nollie can't use your Mac in a scheduled or unattended run. "
              "Ask the person to do it, or use the bot's own computer.")


def _nobody_can_answer():
    """True when no person could answer an approval for this run. Any doubt counts as nobody."""
    try:
        from tools.approval_context import _is_cron_approval_context, _no_user_can_answer
        return bool(_is_cron_approval_context() or _no_user_can_answer())
    except Exception:
        return True


def _session_env(name):
    try:
        from gateway.session_context import get_session_env
        return get_session_env(name) or ""
    except Exception:
        return ""


def on_pre_tool_call(tool_name="", args=None, session_id=None, nobody_can_answer=None, session_env=None, **_):
    if not str(tool_name).startswith(PREFIX):
        return None
    if (nobody_can_answer or _nobody_can_answer)() or not session_id or str(session_id).startswith("cron_"):
        return {"action": "block", "message": UNATTENDED}
    env = session_env or _session_env
    stamped = dict(args or {})
    stamped["_nollie"] = {
        "session_id": str(session_id),
        # The chat survives Hermes compressing the context, which gives the session a new id.
        "chat": env("HERMES_SESSION_KEY") or str(session_id),
        # The main bot has no profile name in a gateway session.
        "profile": env("HERMES_SESSION_PROFILE") or "default",
        "platform": env("HERMES_SESSION_PLATFORM"),
    }
    return {"action": "modify", "args": stamped}


def register(ctx):
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
