"""The crew: Nollie's permanent helpers, each a Hermes profile this add-on created.

Every change goes through ``Crew`` under one file lock. State lives in the main profile's
``nollie-crew/`` folder; a member's own profile carries a matching ownership marker, and
both must agree before anything is changed. The private profile is never opened.
"""
import copy
from pathlib import Path
import secrets
import threading
import time

from . import policy, store
from .policy import CAP, MAIN, PRIVATE, CrewError

STATE_VERSION = 1
GRANT_SECONDS = 20 * 60


def _ok(**values):
    return {"ok": True, **values}


def _error(message, **values):
    return {"ok": False, "error": message, **values}


class Approvals:
    """The person's answers from Hermes's approval prompt, kept in memory for one request each.

    ``asked`` is recorded when the approval hook sends a request to the prompt; ``granted`` only
    when Hermes reports the person's answer. A tool call proceeds with the granted request alone.
    """

    def __init__(self, clock=time.time):
        self._clock = clock
        self._asked = {}
        self._granted = {}
        self._lock = threading.Lock()

    def _fresh(self, table):
        cutoff = self._clock() - GRANT_SECONDS
        for key in [k for k, at in table.items() if at < cutoff]:
            table.pop(key, None)

    def ask(self, digest):
        with self._lock:
            self._fresh(self._asked)
            self._asked[digest] = self._clock()

    def answer(self, digest, choice):
        with self._lock:
            self._fresh(self._asked)
            if digest in self._asked and choice in ("once", "session", "always"):
                self._asked.pop(digest)
                self._granted[digest] = self._clock()
                return True
            self._asked.pop(digest, None)
            return False

    def granted(self, digest):
        with self._lock:
            self._fresh(self._granted)
            return digest in self._granted

    def spend(self, digest):
        with self._lock:
            self._granted.pop(digest, None)


class Crew:
    def __init__(self, profiles, root, *, clock=time.time, token=None):
        self.profiles = profiles
        self.root = Path(root)               # <main home>/nollie-crew
        self.clock = clock
        self.token = token or (lambda: secrets.token_urlsafe(12))

    # State ----------------------------------------------------------------------------
    @property
    def lock_path(self):
        return self.root / "state.lock"

    def read_state(self):
        state = store.read_json(self.root / "state.json")
        if state is None:
            return {"version": STATE_VERSION, "members": {}, "retired": {}, "undo": {},
                    "suggestions": {}, "declined": []}
        if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
            raise ValueError("crew state needs repair")
        for key, kind in (("members", dict), ("retired", dict), ("undo", dict), ("suggestions", dict),
                          ("declined", list)):
            if not isinstance(state.setdefault(key, kind()), kind):
                raise ValueError("crew state needs repair")
        return state

    def write_state(self, state):
        undo = state["undo"]
        if len(undo) > 64:  # keep recent undo tokens only
            for key in sorted(undo, key=lambda k: undo[k].get("at", 0))[:len(undo) - 64]:
                undo.pop(key)
        store.write_json(self.root / "state.json", state)

    def settings(self):
        value = store.read_json(self.root / "settings.json", {})
        return value if isinstance(value, dict) else {}

    def _nollie(self):
        if self.profiles.is_private(MAIN):
            raise CrewError("That bot is private, so I leave it alone.")
        return self.profiles.read_config(MAIN)

    def _names(self):
        ids = [i for i in self.profiles.profile_ids()]
        names = []
        for profile_id in ids:
            if self.profiles.is_private(profile_id):
                continue
            try:
                names.append(self.profiles.display_name(profile_id))
            except (OSError, ValueError):
                continue
        return ids, names

    def _owned(self, state, name):
        """The member record for ``name`` (display name or id), only if this add-on owns it."""
        if not isinstance(name, str) or not name.strip():
            raise CrewError("Say which crew member.")
        wanted = name.strip().casefold()
        if wanted in (PRIVATE, "moss"):
            raise CrewError("That bot is private, so I leave it alone.")
        if wanted in (MAIN, "nollie"):
            raise CrewError("Nollie isn't a crew member.")
        for profile_id, member in state["members"].items():
            if wanted in (profile_id, member["name"].casefold()):
                if self.profiles.is_private(profile_id):
                    raise CrewError("That bot is private, so I leave it alone.")
                marker = self.profiles.read_marker(profile_id)
                if not marker or marker.get("id") != member["marker"]:
                    raise CrewError(f"{member['name']} has changed outside the crew, so I won't touch them.")
                return profile_id, member
        raise CrewError(f"{name.strip()} isn't someone I added to the crew, so I can't change them.")

    def _undo_token(self, state, kind, profile_id, **data):
        token = self.token()
        state["undo"][token] = {"kind": kind, "profile": profile_id, "at": int(self.clock()), **data}
        return token

    @staticmethod
    def _meet(profile_id, name):
        return {"id": "meet", "label": "Meet", "profile": profile_id, "name": name}

    def _active_count(self, state):
        return sum(1 for m in state["members"].values() if m.get("status") in ("active", "paused"))

    # Reading -----------------------------------------------------------------------
    def list(self):
        with store.file_lock(self.lock_path):
            state = self.read_state()
        members = []
        for profile_id, m in sorted(state["members"].items()):
            if self.profiles.is_private(profile_id):
                continue
            members.append({"profile": profile_id, "name": m["name"], "role": m["role"],
                            "come_to_me_for": m["come_to_me_for"], "status": m["status"],
                            "toolsets": m["reach"]["toolsets"] + m["reach"]["mcp_servers"],
                            "model_route": m["reach"]["model_route"], "schedule": m.get("schedule")})
        ids, _ = self._names()
        others = [i for i in ids if i not in state["members"] and i != MAIN and not self.profiles.is_private(i)]
        open_ideas = [dict(id=key, **{k: v for k, v in s.items() if k in ("name", "role", "note", "needs")})
                      for key, s in state["suggestions"].items() if s["status"] == "open"]
        return _ok(members=members, cap=CAP, room=max(0, CAP - self._active_count(state)),
                   other_bots=others, suggestion=open_ideas[0] if open_ideas else None)

    # Planning (no changes) -----------------------------------------------------------
    def _plan_add(self, args, state):
        name = policy.clean_name(args.get("name"))
        profile_id = policy.profile_id_for(name)
        self.profiles.workflow.prepare(profile_id)
        role = policy.clean_role(args.get("role"))
        come = policy.clean_come_to_me_for(args.get("come_to_me_for"))
        schedule = policy.clean_schedule(args.get("schedule"))
        nollie = self._nollie()
        reach = policy.resolve_reach(nollie, args.get("toolsets"), args.get("model_route"))
        ids, names = self._names()
        policy.check_name_free(name, profile_id, ids, names)
        needs = policy.needs_for(reach, schedule, nollie)
        return {"name": name, "profile": profile_id, "role": role, "come_to_me_for": come,
                "schedule": schedule, "reach": reach, "needs": needs, "nollie": nollie}

    def approval_request(self, tool, args):
        """For the approval hook: what the person must agree to before ``tool`` runs, or None."""
        try:
            with store.file_lock(self.lock_path):
                state = self.read_state()
                if tool == "crew_add":
                    if args.get("asked_by_person") is not True:
                        return None
                    plan = self._plan_add(args, state)
                    if not plan["needs"]:
                        return None
                    return policy.approval_message("add", plan["name"], plan["needs"])
                if tool == "crew_update":
                    plan = self._plan_update(args, state)
                    if not plan or not plan["needs"]:
                        return None
                    return policy.approval_message("change", plan["member"]["name"], plan["needs"])
        except (CrewError, ValueError, OSError):
            return None  # the tool itself reports the problem
        return None

    # Adding ------------------------------------------------------------------------
    def add(self, args, *, approved=False, actor="nollie"):
        if not isinstance(args, dict):
            return _error("The request was not understood.")
        with store.file_lock(self.lock_path):
            state = self.read_state()
            try:
                plan = self._plan_add(args, state)
            except CrewError as error:
                return _error(str(error))
            if self._active_count(state) >= CAP:
                return _error(f"The crew is full ({CAP}). Retire someone first.", status="full")
            if actor == "nollie" and args.get("asked_by_person") is not True:
                return self._suggest(state, plan, args)
            if plan["needs"] and not approved:
                return _ok(status="needs_approval", needs=plan["needs"],
                           message=policy.approval_message("add", plan["name"], plan["needs"]),
                           note="Ask the person first. Their answer comes from the approval prompt, "
                                "then call crew_add again with the same details.")
            return self._create(state, plan, origin="person" if actor == "person" else "asked")

    def _suggest(self, state, plan, args):
        words = policy.idea_words(plan["role"])
        for declined in state["declined"]:
            if declined.get("profile") == plan["profile"] or policy.same_idea(words, declined.get("words", [])):
                return _ok(status="declined_before",
                           note="The person said not now to this idea. Don't offer it again.")
        for key, suggestion in state["suggestions"].items():
            if suggestion["status"] == "open":
                return _ok(status="suggestion_waiting", suggestion=key,
                           note="One idea at a time: wait for the person to answer the open suggestion.")
        key = self.token()
        note = policy.suggestion_note(plan["name"], plan["role"], plan["needs"])
        state["suggestions"][key] = {"status": "open", "name": plan["name"], "role": plan["role"],
                                     "profile": plan["profile"], "words": words, "note": note,
                                     "needs": plan["needs"], "at": int(self.clock()),
                                     "args": {k: copy.deepcopy(v) for k, v in args.items()
                                              if k in ("name", "role", "come_to_me_for", "schedule",
                                                       "toolsets", "model_route")}}
        self.write_state(state)
        return _ok(status="suggestion", suggestion=key, note=note,
                   actions=[{"id": "add", "label": "Add", "suggestion": key},
                            {"id": "not_now", "label": "Not now", "suggestion": key}])

    def _create(self, state, plan, *, origin):
        nollie = plan["nollie"]
        config = policy.member_config(nollie, plan["reach"], self.settings(), self.profiles.platforms())
        problems = policy.exceeds(config, nollie)
        if problems:  # belt and braces: never write a member that reaches past Nollie
            return _error("That would give the crew member more than Nollie has.", problems=problems)
        marker = {"owner": "nollie-crew", "id": self.token(), "created_at": int(self.clock())}
        profile_id, name = plan["profile"], plan["name"]
        try:
            self.profiles.create(profile_id, config=config, soul=policy.persona(name, plan["role"], plan["come_to_me_for"]),
                                 display_name=name, description=plan["come_to_me_for"], marker=marker)
            job = None
            if plan["schedule"]:
                job = self.profiles.add_schedule(profile_id, when=plan["schedule"]["when"],
                                                 task=plan["schedule"]["task"], name=f"{name}: {plan['role']}")
        except Exception:
            self._discard_half_made(profile_id, marker["id"])
            raise
        changes = [f"Added {name} to the crew", "Tools: " + (", ".join(
            plan["reach"]["toolsets"] + plan["reach"]["mcp_servers"]) or "none"),
            "Model: " + ("your online plan" if plan["reach"]["model_route"] == "plan" else "local, on this Mac")]
        member = {"name": name, "role": plan["role"], "come_to_me_for": plan["come_to_me_for"],
                  "status": "active", "marker": marker["id"], "created_at": marker["created_at"],
                  "origin": origin, "reach": plan["reach"], "schedule": None, "jobs": []}
        if job:
            member["schedule"], member["jobs"] = plan["schedule"], [job]
            changes.append(f"Schedule: {plan['schedule']['when']}")
        state["members"][profile_id] = member
        token = self._undo_token(state, "add", profile_id, marker=marker["id"])
        self.write_state(state)
        return _ok(status="added", profile=profile_id, name=name, changes=changes,
                   note=policy.added_note(name, plan["role"]), undo=token,
                   actions=[self._meet(profile_id, name), {"id": "undo", "label": "Undo", "token": token}])

    def _discard_half_made(self, profile_id, marker_id):
        """A create that failed part way: remove the profile only if it carries this attempt's marker."""
        try:
            found = self.profiles.read_marker(profile_id)
            if found and found.get("id") == marker_id:
                self.profiles.remove(profile_id)
        except Exception:
            pass

    def answer_suggestion(self, key, answer):
        """The person's tap on a suggestion card: ``add`` or ``not_now``."""
        with store.file_lock(self.lock_path):
            state = self.read_state()
            suggestion = state["suggestions"].get(key)
            if not suggestion or suggestion["status"] != "open":
                return _error("That suggestion has already been answered.")
            if answer == "not_now":
                suggestion["status"] = "not_now"
                state["declined"].append({"profile": suggestion["profile"], "words": suggestion["words"],
                                          "at": int(self.clock())})
                self.write_state(state)
                return _ok(status="not_now", note="Okay, I won't suggest that again.")
            if answer != "add":
                return _error("Answer with add or not_now.")
            args = dict(suggestion["args"], asked_by_person=True)
            if isinstance(args.get("schedule"), dict):
                args["schedule"] = dict(args["schedule"], asked_by_person=True)
            try:
                plan = self._plan_add(args, state)
            except CrewError as error:
                return _error(str(error))
            if self._active_count(state) >= CAP:
                return _error(f"The crew is full ({CAP}). Retire someone first.", status="full")
            # The card named everything the member would use; the tap is the person's yes.
            result = self._create(state, plan, origin="suggestion")
            if result["ok"]:
                state = self.read_state()
                state["suggestions"][key]["status"] = "added"
                self.write_state(state)
            return result

    # Changing ----------------------------------------------------------------------
    def _plan_update(self, args, state):
        profile_id, member = self._owned(state, args.get("name"))
        nollie = self._nollie()
        fields = {}
        if args.get("new_name") is not None:
            new_name = policy.clean_name(args["new_name"])
            if new_name.casefold() != member["name"].casefold():
                ids, names = self._names()
                own = self.profiles.display_name(profile_id)
                policy.check_name_free(new_name, policy.profile_id_for(new_name),
                                       [i for i in ids if i != profile_id], [n for n in names if n != own])
            fields["name"] = new_name
        if args.get("role") is not None:
            fields["role"] = policy.clean_role(args["role"])
        if args.get("come_to_me_for") is not None:
            fields["come_to_me_for"] = policy.clean_come_to_me_for(args["come_to_me_for"])
        schedule = policy.clean_schedule(args["schedule"]) if args.get("schedule") is not None else None
        if args.get("toolsets") is not None or args.get("model_route") is not None:
            reach = policy.resolve_reach(
                nollie, args["toolsets"] if args.get("toolsets") is not None
                else member["reach"]["toolsets"] + member["reach"]["mcp_servers"],
                args.get("model_route") or member["reach"]["model_route"])
        else:
            reach = None
        before = member["reach"]
        needs = policy.needs_for(reach or before, schedule, nollie, before=before)
        return {"profile": profile_id, "member": member, "fields": fields, "reach": reach,
                "schedule": schedule, "clear_schedule": args.get("clear_schedule") is True,
                "needs": needs, "nollie": nollie}

    def update(self, args, *, approved=False):
        if not isinstance(args, dict):
            return _error("The request was not understood.")
        with store.file_lock(self.lock_path):
            state = self.read_state()
            try:
                plan = self._plan_update(args, state)
            except CrewError as error:
                return _error(str(error))
            if plan["needs"] and not approved:
                return _ok(status="needs_approval", needs=plan["needs"],
                           message=policy.approval_message("change", plan["member"]["name"], plan["needs"]),
                           note="Ask the person first, then call crew_update again with the same details.")
            profile_id, member = plan["profile"], plan["member"]
            if not (plan["fields"] or plan["reach"] or plan["schedule"] or plan["clear_schedule"]):
                return _error("Nothing to change.")
            before = {"record": copy.deepcopy(member), "files": self.profiles.snapshot(profile_id)}
            updated = dict(member, **plan["fields"])
            changes = [f"{key.replace('_', ' ').capitalize()}: {value}" for key, value in plan["fields"].items()]
            config = None
            if plan["reach"]:
                config = policy.member_config(plan["nollie"], plan["reach"], self.settings(), self.profiles.platforms())
                if policy.exceeds(config, plan["nollie"]):
                    return _error("That would give the crew member more than Nollie has.")
                updated["reach"] = plan["reach"]
                changes.append("Tools: " + (", ".join(plan["reach"]["toolsets"] + plan["reach"]["mcp_servers"]) or "none"))
                if plan["reach"]["model_route"] != member["reach"]["model_route"]:
                    changes.append("Model: " + ("your online plan" if plan["reach"]["model_route"] == "plan"
                                                else "local, on this Mac"))
            soul = None
            if {"name", "role", "come_to_me_for"} & set(plan["fields"]):
                soul = policy.persona(updated["name"], updated["role"], updated["come_to_me_for"])
            self.profiles.write_files(profile_id, config=config, soul=soul,
                                      display_name=plan["fields"].get("name"),
                                      description=plan["fields"].get("come_to_me_for"))
            if plan["schedule"] or plan["clear_schedule"]:
                for job in member.get("jobs", []):
                    self.profiles.remove_schedule(profile_id, job)
                updated["jobs"], updated["schedule"] = [], None
                if plan["schedule"]:
                    job = self.profiles.add_schedule(profile_id, when=plan["schedule"]["when"],
                                                     task=plan["schedule"]["task"],
                                                     name=f"{updated['name']}: {updated['role']}")
                    updated["jobs"], updated["schedule"] = [job], plan["schedule"]
                    if member["status"] == "paused":
                        self.profiles.pause_schedule(profile_id, job)
                    changes.append(f"Schedule: {plan['schedule']['when']}")
                else:
                    changes.append("Schedule: none")
            state["members"][profile_id] = updated
            token = self._undo_token(state, "update", profile_id, before=before)
            self.write_state(state)
            return _ok(status="updated", profile=profile_id, name=updated["name"], changes=changes, undo=token,
                       note=f"I've updated {updated['name']}.",
                       actions=[{"id": "undo", "label": "Undo", "token": token}])

    def pause(self, name):
        return self._set_paused(name, True)

    def resume(self, name):
        return self._set_paused(name, False)

    def _set_paused(self, name, paused, *, undo=True):
        with store.file_lock(self.lock_path):
            state = self.read_state()
            try:
                profile_id, member = self._owned(state, name)
            except CrewError as error:
                return _error(str(error))
            result = self._apply_pause(state, profile_id, member, paused)
            if result["ok"] and undo and result.get("changed"):
                token = self._undo_token(state, "resume" if paused else "pause", profile_id)
                result.update(undo=token, actions=[{"id": "undo", "label": "Undo", "token": token}])
            result.pop("changed", None)
            self.write_state(state)
            return result

    def _apply_pause(self, state, profile_id, member, paused):
        target = "paused" if paused else "active"
        if member["status"] == target:
            return _ok(status=target, profile=profile_id, changed=False,
                       note=f"{member['name']} is already {'paused' if paused else 'working'}.")
        if paused:
            self.profiles.park(profile_id)
            for job in member.get("jobs", []):
                self.profiles.pause_schedule(profile_id, job)
        else:
            for job in member.get("jobs", []):
                self.profiles.resume_schedule(profile_id, job)
            self.profiles.unpark(profile_id)
        member["status"] = target
        state["members"][profile_id] = member
        note = (f"I've paused {member['name']}. Their schedule is on hold." if paused
                else f"{member['name']} is back at work.")
        return _ok(status=target, profile=profile_id, note=note, changed=True)

    def retire(self, name, confirm=False):
        with store.file_lock(self.lock_path):
            state = self.read_state()
            try:
                profile_id, member = self._owned(state, name)
            except CrewError as error:
                return _error(str(error))
            if confirm is not True:
                return _ok(status="needs_confirmation", profile=profile_id, question=policy.retire_question(member["name"]),
                           note="Ask the person. Call crew_retire again with confirm true only after they say yes.")
            archive = self._take_down(profile_id)
            state["members"].pop(profile_id)
            state["retired"][profile_id] = dict(member, archive=archive, retired_at=int(self.clock()))
            token = self._undo_token(state, "retire", profile_id, archive=archive, marker=member["marker"])
            self.write_state(state)
            return _ok(status="retired", profile=profile_id, undo=token,
                       note=f"{member['name']} has retired. I kept a copy of their chats.",
                       actions=[{"id": "undo", "label": "Undo", "token": token}])

    def _take_down(self, profile_id):
        archive = self.profiles.archive(profile_id, self.root / "archives")
        self.profiles.remove(profile_id)
        return archive

    # Undo --------------------------------------------------------------------------
    def undo(self, token):
        with store.file_lock(self.lock_path):
            state = self.read_state()
            entry = state["undo"].get(token) if isinstance(token, str) else None
            if not entry or entry.get("used"):
                return _error("There's nothing to undo for that.")
            kind, profile_id = entry["kind"], entry["profile"]
            try:
                if self.profiles.is_private(profile_id):
                    raise CrewError("That bot is private, so I leave it alone.")
                result = getattr(self, "_undo_" + kind)(state, profile_id, entry)
            except CrewError as error:
                return _error(str(error))
            if result["ok"]:
                entry["used"] = int(self.clock())
            self.write_state(state)
            return result

    def _current(self, state, profile_id, marker=None):
        member = state["members"].get(profile_id)
        if not member or (marker and member["marker"] != marker):
            raise CrewError("That crew member has already changed, so there's nothing to undo.")
        found = self.profiles.read_marker(profile_id)
        if not found or found.get("id") != member["marker"]:
            raise CrewError(f"{member['name']} has changed outside the crew, so I won't touch them.")
        return member

    def _undo_add(self, state, profile_id, entry):
        member = self._current(state, profile_id, entry.get("marker"))
        archive = self._take_down(profile_id)
        state["members"].pop(profile_id)
        state["retired"][profile_id] = dict(member, archive=archive, retired_at=int(self.clock()), undone=True)
        return _ok(status="removed", profile=profile_id, note=f"I've removed {member['name']}.")

    def _undo_retire(self, state, profile_id, entry):
        member = state["retired"].get(profile_id)
        if not member or member.get("marker") != entry.get("marker"):
            raise CrewError("That crew member can't be brought back.")
        if profile_id in self.profiles.profile_ids():
            raise CrewError(f"The name {member['name']} is taken now, so I can't bring them back.")
        if self._active_count(state) >= CAP:
            raise CrewError(f"The crew is full ({CAP}). Retire someone first.")
        self.profiles.restore(member["archive"], profile_id)
        restored = {k: v for k, v in member.items() if k not in ("archive", "retired_at", "undone")}
        state["members"][profile_id] = restored
        state["retired"].pop(profile_id)
        return _ok(status=restored["status"], profile=profile_id, note=f"{restored['name']} is back.",
                   actions=[self._meet(profile_id, restored["name"])])

    def _undo_pause(self, state, profile_id, entry):
        member = self._current(state, profile_id)
        result = self._apply_pause(state, profile_id, member, True)
        result.pop("changed", None)
        return result

    def _undo_resume(self, state, profile_id, entry):
        member = self._current(state, profile_id)
        result = self._apply_pause(state, profile_id, member, False)
        result.pop("changed", None)
        return result

    def _undo_update(self, state, profile_id, entry):
        member = self._current(state, profile_id)
        before = entry["before"]
        files = before["files"]
        self.profiles.write_files(profile_id, config=files["config"], soul=files["soul"],
                                  display_name=files["display_name"], description=files["description"])
        record = copy.deepcopy(before["record"])
        if record.get("jobs") != member.get("jobs"):
            for job in member.get("jobs", []):
                self.profiles.remove_schedule(profile_id, job)
            record["jobs"] = []
            if record.get("schedule"):
                job = self.profiles.add_schedule(profile_id, when=record["schedule"]["when"],
                                                 task=record["schedule"]["task"],
                                                 name=f"{record['name']}: {record['role']}")
                record["jobs"] = [job]
                if member["status"] == "paused":
                    self.profiles.pause_schedule(profile_id, job)
        record["status"] = member["status"]
        state["members"][profile_id] = record
        return _ok(status="restored", profile=profile_id, note=f"{record['name']} is back to how they were.")
