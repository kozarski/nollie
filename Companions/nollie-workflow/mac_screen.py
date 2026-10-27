"""This Mac's screen stays on this Mac: Hermes's own ``computer_use`` is refused for every bot that is not private.

``computer_use`` hands whole screenshots of the Mac, and the screen's words, to the bot's own model (often an
online one), in any app. Nollie's way (the nollie-mac add-on: ``mac_start``, then ``mac_do``) works only in the
apps the person picked, a model on the Mac does the clicking, and only a short sentence comes back. A fixed rule,
never the model's judgement: the call is refused before it runs, and a result that got through anyway is
replaced, with Hermes's cached copy of its picture removed. Bots' own computers (``mcp__cua__*``) are theirs, not
this Mac, and are left alone.
"""

TOOLS = frozenset({"computer_use"})
MESSAGE = ("Not done: this Mac's screen stays on this Mac. To use apps here, ask with mac_start and then mac_do: "
           "a model on the Mac does the clicking, in the apps the person picked.")
REPLACED = "This Mac's screen stays on this Mac, so what that call saw was thrown away."


def refuse(tool_name=None, args=None, **_):
    """``pre_tool_call``."""
    if str(tool_name or "") in TOOLS:
        return {"action": "block", "message": MESSAGE}
    return None


def scrub(tool_name=None, args=None, result=None, **_):
    """``transform_tool_result``: nothing a ``computer_use`` call saw reaches the model."""
    if str(tool_name or "") not in TOOLS:
        return None
    try:
        from .sign_ins import _remove_cached_pictures
        _remove_cached_pictures(result)
    except Exception:
        pass
    return REPLACED


def register(ctx):
    ctx.register_hook("pre_tool_call", refuse)
    ctx.register_hook("transform_tool_result", scrub)
