"""Limits for work passed between bots: two levels at most, no loops, and a pause to ask
the person after about twelve bot-to-bot messages without them.

A chain is the list of bots a piece of work has passed through, starting with the bot the
person spoke to: ``["default", "scout"]`` means Nollie handed the work to Scout. Counters are
per conversation and reset when the person speaks. See the README for where Hermes calls in.
"""
from pathlib import Path

from . import store

MAX_LEVELS = 2
PAUSE_AFTER = 12


def check_handoff(chain, to):
    """Whether the last bot in ``chain`` may hand work to ``to``."""
    chain = [str(bot) for bot in chain or []]
    if not chain:
        return {"ok": False, "reason": "no_chain", "message": "A handoff needs the bot that is handing over."}
    if to in chain:
        return {"ok": False, "reason": "loop",
                "message": f"That would send the work back to {to}, so it stays here."}
    if len(chain) > MAX_LEVELS:
        return {"ok": False, "reason": "too_deep",
                "message": "This has already been passed on twice. Finish it here or ask the person."}
    return {"ok": True, "chain": chain + [to], "level": len(chain)}


def pause_question(count):
    return (f"The crew has sent {count} messages to each other without you. "
            "Should they keep going?")


class Conversations:
    """Bot-to-bot message counts since the person last spoke, saved beside the crew state."""

    def __init__(self, root):
        self.path = Path(root) / "handoffs.json"
        self.lock = Path(root) / "handoffs.lock"

    def _read(self):
        value = store.read_json(self.path, {})
        return value if isinstance(value, dict) else {}

    def _update(self, conversation, change):
        if not isinstance(conversation, str) or not conversation:
            raise ValueError("conversation id required")
        with store.file_lock(self.lock):
            data = self._read()
            entry = data.get(conversation) if isinstance(data.get(conversation), dict) else {}
            entry = {"since_person": int(entry.get("since_person", 0)), "paused": bool(entry.get("paused"))}
            result = change(entry)
            data[conversation] = entry
            if len(data) > 512:  # oldest conversations fall away
                for key in list(data)[:len(data) - 512]:
                    data.pop(key)
            store.write_json(self.path, data)
            return result

    def person_spoke(self, conversation):
        def change(entry):
            entry.update(since_person=0, paused=False)
            return {"ok": True}
        return self._update(conversation, change)

    def bot_message(self, conversation):
        """Count one bot-to-bot message. Past the limit the crew pauses until the person answers."""
        def change(entry):
            if entry["paused"]:
                return {"ok": False, "paused": True, "question": pause_question(entry["since_person"])}
            entry["since_person"] += 1
            if entry["since_person"] >= PAUSE_AFTER:
                entry["paused"] = True
                return {"ok": False, "paused": True, "question": pause_question(entry["since_person"])}
            return {"ok": True, "count": entry["since_person"], "left": PAUSE_AFTER - entry["since_person"]}
        return self._update(conversation, change)

    def handoff(self, conversation, chain, to):
        """Check a handoff and count it as a bot-to-bot message."""
        verdict = check_handoff(chain, to)
        if not verdict["ok"]:
            return verdict
        counted = self.bot_message(conversation)
        if not counted["ok"]:
            return {"ok": False, "reason": "paused", "message": counted["question"]}
        return dict(verdict, left=counted["left"])
