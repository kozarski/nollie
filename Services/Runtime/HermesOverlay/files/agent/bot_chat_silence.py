"""Presentation of successful machine-turn control markers; raw history stays intact."""
from __future__ import annotations

import os

MACHINE_TURN_ENV = "HERMES_BOT_CHAT_MACHINE_TURN"


def bind_machine_turn(agent, display_kind, *, environ=None):
    """Reset per turn. A one-shot child consumes its typed origin before it can spawn tools."""
    from gateway.response_filters import INTERNAL_NOTIFICATION_DISPLAY_KIND
    env = os.environ if environ is None else environ
    inherited = env.pop(MACHINE_TURN_ENV, None) == "1"
    if inherited and display_kind is None:
        display_kind = INTERNAL_NOTIFICATION_DISPLAY_KIND
    agent._machine_control_turn = display_kind == INTERNAL_NOTIFICATION_DISPLAY_KIND
    return display_kind


def mark_silent_final(agent, message, response, *, successful):
    """Hide only an exact final control marker from a trusted machine turn, never human text."""
    from gateway.response_filters import is_intentional_silence_response
    if (not successful or not getattr(agent, "_machine_control_turn", False)
            or not isinstance(message, dict) or message.get("role") != "assistant"
            or message.get("tool_calls") or message.get("content") != response
            or not is_intentional_silence_response(response)):
        return False
    message["display_kind"] = "hidden"
    metadata = dict(message.get("display_metadata") or {})
    metadata["control_marker"] = "intentional_silence"
    message["display_metadata"] = metadata
    return True
