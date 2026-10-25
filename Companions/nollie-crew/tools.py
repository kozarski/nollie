"""Crew tools for Nollie, the approval hook and their schemas.

Only the main profile gets these tools, and every call checks again who is calling.
Requests that need the person (the Mac, the online plan, connections, a schedule Nollie
picked, messaging other people) go through Hermes's own approval prompt: the
``pre_tool_call`` hook asks for it and ``post_approval_response`` records the person's answer.
A call without that recorded answer returns ``needs_approval`` and changes nothing.
"""
import json

from .crew import Approvals, Crew
from .policy import MAIN, request_digest

TOOLSET = "nollie_crew"
GUARDED = ("crew_add", "crew_update")
RULE_PREFIX = "plugin_rule:nollie-crew:"
CHANGES = frozenset({"crew_add", "crew_update", "crew_pause", "crew_resume", "crew_retire", "crew_undo",
                     "crew_not_now"})

_NAME = {"type": "string", "description": "The crew member's name, like Scout."}
_SCHEDULE = {"type": "object", "additionalProperties": False, "properties": {
    "when": {"type": "string", "description": "Cron expression or Hermes schedule, like '0 8 * * *'."},
    "task": {"type": "string", "description": "What the member does on each run, in one or two sentences."},
    "asked_by_person": {"type": "boolean", "description": "True only when the person gave this timing. A timing you picked needs their OK."}},
    "required": ["when", "task", "asked_by_person"]}
_TOOLSETS = {"type": "array", "items": {"type": "string"},
             "description": "Hermes toolsets for the member. Never more than Nollie has. Leave out for the safe default."}
_ROUTE = {"type": "string", "enum": ["local", "plan"],
          "description": "local (default) runs on this Mac. plan uses the person's online plan and needs their OK."}

SCHEMAS = {
    "crew_add": {
        "description": (
            "Add a permanent crew member (its own bot) when ongoing work needs a specialist. If the person asked for "
            "this work, set asked_by_person true: the member is added and the result has a short chat note with Meet "
            "and Undo; show the note as it is. If it's your own idea, set asked_by_person false: nothing is created "
            "and the result is a one-tap suggestion (Add, Not now) for the person. One suggestion at a time; never "
            "offer an idea again after Not now. Use delegate_task instead for one-off jobs. At most 8 members."),
        "parameters": {"type": "object", "additionalProperties": False, "properties": {
            "name": _NAME,
            "role": {"type": "string", "description": "What they do, as a short phrase that fits 'I've added Scout to ...', like 'check new roles each morning'."},
            "come_to_me_for": {"type": "string", "description": "One or two sentences, in the member's voice, saying what to bring to them. You read this when routing work."},
            "asked_by_person": {"type": "boolean", "description": "True only when the person asked for this work."},
            "schedule": _SCHEDULE, "toolsets": _TOOLSETS, "model_route": _ROUTE},
            "required": ["name", "role", "come_to_me_for", "asked_by_person"]}},
    "crew_list": {
        "description": "List the crew: names, roles, 'come to me for' lines, status and room left. Read this before routing work.",
        "parameters": {"type": "object", "additionalProperties": False, "properties": {}}},
    "crew_update": {
        "description": "Change a crew member you added: name, role, 'come to me for', schedule, toolsets or model route. The result has an Undo.",
        "parameters": {"type": "object", "additionalProperties": False, "properties": {
            "name": _NAME, "new_name": {"type": "string"}, "role": {"type": "string"},
            "come_to_me_for": {"type": "string"}, "schedule": _SCHEDULE,
            "clear_schedule": {"type": "boolean", "description": "Remove the member's schedule."},
            "toolsets": _TOOLSETS, "model_route": _ROUTE},
            "required": ["name"]}},
    "crew_pause": {
        "description": "Pause a crew member: their schedule stops until resumed. The result has an Undo.",
        "parameters": {"type": "object", "additionalProperties": False, "properties": {"name": _NAME}, "required": ["name"]}},
    "crew_resume": {
        "description": "Resume a paused crew member.",
        "parameters": {"type": "object", "additionalProperties": False, "properties": {"name": _NAME}, "required": ["name"]}},
    "crew_retire": {
        "description": ("Retire a crew member. Without confirm it returns a question for the person; call again with "
                        "confirm true only after they say yes. Their chats are kept and the result has an Undo."),
        "parameters": {"type": "object", "additionalProperties": False, "properties": {
            "name": _NAME, "confirm": {"type": "boolean"}}, "required": ["name"]}},
    "crew_undo": {
        "description": "Undo a crew change with the undo token from its result, when the person asks.",
        "parameters": {"type": "object", "additionalProperties": False, "properties": {
            "token": {"type": "string"}}, "required": ["token"]}},
    "crew_not_now": {
        "description": "Record that the person said not now to your open crew suggestion, so it is never offered again.",
        "parameters": {"type": "object", "additionalProperties": False, "properties": {
            "suggestion": {"type": "string"}}, "required": ["suggestion"]}},
}


class CrewTools:
    def __init__(self, crew: Crew, caller, approvals: Approvals = None):
        self.crew = crew
        self.caller = caller
        self.approvals = approvals or Approvals()

    # Hooks -----------------------------------------------------------------------
    def pre_tool_call(self, tool_name=None, args=None, **_):
        if tool_name not in GUARDED or not isinstance(args, dict) or not self._is_main():
            return None
        message = self.crew.approval_request(tool_name, args)
        if not message:
            return None
        digest = request_digest(tool_name, args)
        self.approvals.ask(digest)
        return {"action": "approve", "message": message, "rule_key": "nollie-crew:" + digest}

    def post_approval_response(self, pattern_key=None, pattern_keys=None, choice=None, **_):
        keys = [pattern_key] + list(pattern_keys or [])
        for key in keys:
            if isinstance(key, str) and key.startswith(RULE_PREFIX):
                self.approvals.answer(key[len(RULE_PREFIX):], choice)

    # Calls -----------------------------------------------------------------------
    def _is_main(self):
        try:
            return self.caller().get("profile") == MAIN
        except Exception:
            return False

    def handle(self, tool_name, args):
        try:
            who = self.caller()
        except Exception:
            who = {}
        if who.get("profile") != MAIN:
            return _dump({"ok": False, "error": "Only Nollie can manage the crew."})
        if not isinstance(args, dict):
            return _dump({"ok": False, "error": "The request was not understood."})
        is_suggestion = tool_name == "crew_add" and args.get("asked_by_person") is not True
        if tool_name in CHANGES and (who.get("helper") or (who.get("scheduled") and not is_suggestion)):
            return _dump({"ok": False, "error": "Crew changes happen in a conversation with the person, not in a helper or a scheduled run."})
        try:
            return _dump(self._dispatch(tool_name, args))
        except Exception as error:  # a lost result is uncertain, never a reason to repeat a change
            return _dump({"ok": False, "error": "The crew change could not be confirmed. Check crew_list before retrying.",
                          "detail": type(error).__name__})

    def _dispatch(self, tool_name, args):
        crew = self.crew
        if tool_name == "crew_list":
            return crew.list()
        if tool_name in GUARDED:
            digest = request_digest(tool_name, args)
            approved = self.approvals.granted(digest)
            result = crew.add(args, approved=approved) if tool_name == "crew_add" else crew.update(args, approved=approved)
            if result.get("ok") and result.get("status") in ("added", "updated"):
                self.approvals.spend(digest)
            return result
        if tool_name == "crew_pause":
            return crew.pause(args.get("name"))
        if tool_name == "crew_resume":
            return crew.resume(args.get("name"))
        if tool_name == "crew_retire":
            return crew.retire(args.get("name"), confirm=args.get("confirm") is True)
        if tool_name == "crew_undo":
            return crew.undo(args.get("token"))
        if tool_name == "crew_not_now":
            return crew.answer_suggestion(args.get("suggestion"), "not_now")
        return {"ok": False, "error": "Unknown crew tool."}

    def register(self, ctx):
        for name, schema in SCHEMAS.items():
            ctx.register_tool(name=name, toolset=TOOLSET, schema={"name": name, **schema},
                              handler=lambda args, _name=name, **_: self.handle(_name, args),
                              description=schema["description"])
        ctx.register_hook("pre_tool_call", self.pre_tool_call)
        ctx.register_hook("post_approval_response", self.post_approval_response)


def _dump(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False)
