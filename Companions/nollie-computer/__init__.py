"""The dashboard mounts the preview and control API. One hook pauses Cua computer tools while a
person has taken over the bot's computer in Nollie; nothing runs in the background."""
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location("nollie_computer_takeover_hook",
                                               Path(__file__).with_name("dashboard") / "takeover_core.py")
_takeover = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_takeover)


def _on_pre_tool_call(tool_name: str = "", args=None, **_):
    message = _takeover.blocked_message(tool_name, args)
    return {"action": "block", "message": message} if message else None


def register(ctx):
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
