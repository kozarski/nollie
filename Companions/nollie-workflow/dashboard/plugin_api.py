"""Hermes authenticates this namespace. Profile and task filters stay server-owned."""
import importlib.util
from pathlib import Path
import re
import sys
import time

from fastapi import APIRouter, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

_name = "nollie_workflow_dashboard"
_root = Path(__file__).resolve().parent.parent
if _name not in sys.modules:
    _spec = importlib.util.spec_from_file_location(_name, _root / "__init__.py",
                                                 submodule_search_locations=[str(_root)])
    _module = importlib.util.module_from_spec(_spec)
    sys.modules[_name] = _module
    _spec.loader.exec_module(_module)
_core = __import__(_name + ".workflow_core", fromlist=["status"])
_adapter = __import__(_name + ".hermes_adapter", fromlist=["BoardSource"])
_private = __import__(_name + ".private_bots", fromlist=["read"])
_looks = __import__(_name + ".bot_looks", fromlist=["read"])
_papertrail = __import__(_name + ".papertrail", fromlist=["read"])
_posts = __import__(_name + ".posts", fromlist=["PostStore"])
_night = __import__(_name + ".night_service", fromlist=["turn_on"])
_shift = __import__(_name + ".night_shift", fromlist=["without_private"])
_sleep = __import__(_name + ".sleep_watch", fromlist=["gaps"])
_sign_ins = __import__(_name + ".sign_ins", fromlist=["Store"])
_apple = __import__(_name + ".apple_data", fromlist=["Store"])
_memory = __import__(_name + ".memory", fromlist=["Memory"])
_payments = __import__(_name + ".payments", fromlist=["Store"])
_cron_followups = __import__(_name + ".hermes_support.ollie_cron_followups", fromlist=["ready"])
NO_STORE = {"Cache-Control": "no-store"}
router = APIRouter()


def watch_binding_ready():
    try:
        return _cron_followups.ready() is True
    except Exception:
        return False


def home():
    from hermes_cli.profiles import get_active_profile_name, get_profile_dir
    if get_active_profile_name() != "default":
        raise HTTPException(403, "Board follow-through belongs to Nollie.", headers=NO_STORE)
    return Path(get_profile_dir("default"))


@router.get("/status")
def status():
    try:
        result = _core.status(home() / "nollie-workflow")
    except (FileNotFoundError, ValueError):
        raise HTTPException(503, "Board follow-through has not been initialized.") from None
    result.update(plugin_version="0.5.0", watch_binding_ready=watch_binding_ready())
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


class ReadEvents(BaseModel):
    cursors: dict[str, dict[str, int]] = Field(default_factory=dict)


@router.post("/events/read")
def events(body: ReadEvents):
    target = home()
    try:
        state = _core.read_state(target / "nollie-workflow")
        result = _adapter.BoardSource(target).read(body.cursors, state["installed_at"])
    except (FileNotFoundError, ValueError):
        raise HTTPException(503, "Board follow-through is unavailable.") from None
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


@router.get("/attention")
def attention():
    target = home()
    try:
        result = _adapter.BoardSource(target).read({}, 0, include_events=False)
    except ValueError:
        raise HTTPException(503, "Board follow-through is unavailable.") from None
    return JSONResponse({"counts": result["counts"]}, headers=NO_STORE)


@router.get("/private-bots")
def private_bots():
    """The Private list. Before one is saved, bots named private or moss count (saved is false)."""
    try:
        names, saved = _private.read(home())
    except (OSError, ValueError):
        raise HTTPException(503, "The Private list cannot be read.") from None
    return JSONResponse({"profiles": sorted(names), "saved": saved}, headers=NO_STORE)


class PrivateBots(BaseModel):
    profiles: list[str]


@router.put("/private-bots")
def save_private_bots(body: PrivateBots):
    target = home()
    try:
        names = _private.save(target, body.profiles)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    return JSONResponse({"profiles": names, "saved": True}, headers=NO_STORE)


@router.get("/bot-looks")
def bot_looks():
    """Each bot's look as chosen on any of the person's devices. Private bots' looks are left out."""
    target = home()
    try:
        bots, saved = _looks.read(target)
        private = _private.names(target)
    except (OSError, ValueError):
        raise HTTPException(503, "The bots' looks cannot be read.") from None
    return JSONResponse({"bots": _looks.visible(bots, private), "saved": saved}, headers=NO_STORE)


class BotLook(BaseModel):
    look: str | None = None
    colour: str | None = None


@router.put("/bot-looks/{profile}")
def save_bot_look(profile: str, body: BotLook):
    """Keeps one bot's look. A private bot's look stays on the device that chose it."""
    target = home()
    try:
        private = _private.names(target)
    except (OSError, ValueError):
        raise HTTPException(503, "The Private list cannot be read.") from None
    if _private.excluded(profile.strip().lower(), private):
        raise HTTPException(403, "A private bot's look stays on its device.", headers=NO_STORE)
    try:
        bots = _looks.save(target, profile, {"look": body.look, "colour": body.colour})
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    return JSONResponse({"bots": _looks.visible(bots, private), "saved": True}, headers=NO_STORE)


def bot_home(bot, default_home):
    if bot == "default":
        return default_home
    from hermes_cli.profiles import get_profile_dir, profile_exists
    if not profile_exists(bot):
        raise HTTPException(404, "No such bot.", headers=NO_STORE)
    return Path(get_profile_dir(bot))


def papertrail_titles(default_home, bot, private):
    """The names of the bot's schedules and Board tasks, for Papertrail's Why. Read now, never kept in the
    record; a name that holds a private bot's is left out. Best effort: without them the app says "a schedule"."""
    titles = {}
    redactor = _shift.hermes_redactor()
    try:
        for job in _adapter.ProfileJobs(default_home).jobs(bot):
            if isinstance(job.get("id"), str) and isinstance(job.get("name"), str) and job["name"].strip():
                titles[("schedule", job["id"])] = _shift.scrub(job["name"].strip(), redactor, 240)
    except Exception:
        pass
    try:
        for item in _shift.OutcomeLog(Path(default_home) / "nollie-workflow").read():
            if item["assignee"] == bot and item["title"].strip():
                titles[("board", item["task_id"])] = item["title"].strip()[:240]
    except Exception:
        pass
    return {key: title for key, title in titles.items() if not _core.private_identity(title, private)}


@router.get("/papertrail")
def papertrail(bot: str = "default", days: str = "7"):
    """What left this Mac for one bot. Private bots are refused before their home is looked up."""
    target = home()
    if not _private.PROFILE_NAME.match(bot):
        raise HTTPException(422, "Send a bot's Hermes profile name.", headers=NO_STORE)
    if not re.fullmatch(r"[0-9]{1,2}", days) or not 1 <= int(days) <= _papertrail.KEEP_DAYS:
        raise HTTPException(422, f"Send days from 1 to {_papertrail.KEEP_DAYS}.", headers=NO_STORE)
    try:
        private = _private.read(target)[0] | _private.carried_over_names()
    except (OSError, ValueError):
        raise HTTPException(503, "The Private list cannot be read.", headers=NO_STORE) from None
    if _core.private_identity(bot, private):
        raise HTTPException(403, "Papertrail is not kept for private bots.", headers=NO_STORE)
    source = bot_home(bot, target)
    folder = source / "nollie-workflow" / "papertrail"
    if folder.parent.is_symlink() or folder.is_symlink() or not folder.is_dir():
        raise HTTPException(404, "Papertrail is not on for this bot.", headers=NO_STORE)
    try:
        result = _papertrail.read(source, bot, int(days), titles=papertrail_titles(target, bot, private))
    except OSError:
        raise HTTPException(503, "Papertrail cannot be read.", headers=NO_STORE) from None
    return JSONResponse(result, headers=NO_STORE)


POST_ID = re.compile(r"[A-Za-z0-9_-]{1,200}")
POST_DAYS = 14


def visible(post, private):
    """A post with every private bot taken out, or None when the post is about one.

    A morning card is counted again from its per-bot counts, which are never sent.
    """
    if not isinstance(post, dict) or _private.excluded(post.get("bot"), private):
        return None
    if post.get("kind") == "night_shift":
        runs = [r for r in post.get("runs", []) if not _private.excluded(r.get("bot"), private)]
        unwatched = [n for n in post.get("unwatched", []) if not _core.private_identity(n, private)]
        missed = [m for m in post.get("missed", []) if isinstance(m, dict) and not _private.excluded(m.get("bot"), private)]
        by_bot = post.get("by_bot")
        post = {k: v for k, v in post.items() if k not in ("by_bot", "missed")}
        post.update(runs=runs, unwatched=unwatched)
        if missed:
            post["missed"] = missed
        if isinstance(by_bot, dict):
            kept = [c for b, c in by_bot.items() if isinstance(c, dict) and not _private.excluded(b, private)]
            counts = {name: sum(c.get(name) for c in kept if type(c.get(name)) is int) for name in _shift.COUNTS}
            post["counts"] = counts
            post.pop("more_runs", None)
            post.pop("note", None)
            if counts["runs"] > len(runs):
                post["more_runs"] = counts["runs"] - len(runs)
            if not counts["runs"]:
                post["note"] = _shift.QUIET
    return _shift.without_private(post, private)


@router.get("/posts")
def posts(since: int | None = None, limit: int = 60):
    """Night shift and rehearsal cards for Nollie's main chat, oldest first."""
    target = home()
    since = int(time.time()) - POST_DAYS * 86400 if since is None else since
    limit = max(1, min(int(limit), 200))
    try:
        private = _private.names(target) | _private.carried_over_names()
        stored = _posts.PostStore(target / "nollie-workflow").since(since, 10_000)
    except (OSError, ValueError):
        raise HTTPException(503, "Night shift cards are unavailable.") from None
    shown = [p for p in (visible(p, private) for p in stored) if p is not None][-limit:]
    return JSONResponse({"version": 1, "posts": shown}, headers=NO_STORE)


@router.get("/sleep")
def sleep(since: int | None = None):
    """When the Mac was asleep, off, or without Hermes, oldest first: times and a kind, nothing else."""
    target = home()
    now = int(time.time())
    since = now - POST_DAYS * 86400 if since is None else max(int(since), now - _sleep.KEEP_SECONDS)
    gaps = _sleep.gaps(target / "nollie-workflow", since, now + 1)
    return JSONResponse({"version": 1, "gaps": gaps}, headers=NO_STORE)


def schedule_jobs(target):
    return _adapter.ProfileJobs(target)


def card_action(post_id, action):
    target = home()
    if not POST_ID.fullmatch(post_id):
        raise HTTPException(404, "There is no such card.")
    try:
        private = _private.names(target) | _private.carried_over_names()
        stored = _posts.PostStore(target / "nollie-workflow").get(post_id)
        if stored is None or visible(stored, private) is None:
            raise LookupError(post_id)
        post = action(target, post_id, schedule_jobs(target))
    except LookupError:
        raise HTTPException(404, "There is no such card.") from None
    except _night.Conflict as conflict:
        # The card as it is now, with the same private pass as GET /posts.
        shown = visible(conflict.post, private)
        if shown is None:
            raise HTTPException(404, "There is no such card.") from None
        return JSONResponse(shown, status_code=409, headers=NO_STORE)
    except Exception:
        raise HTTPException(503, "Nollie could not change this schedule. Try again in a moment.") from None
    shown = visible(post, private)
    if shown is None:
        raise HTTPException(404, "There is no such card.")
    return JSONResponse(shown, headers=NO_STORE)


@router.post("/rehearsals/{post_id}/turn-on")
def turn_on(post_id: str):
    """Let the schedule run for real from now on. A changed schedule answers 409 and rehearses again."""
    return card_action(post_id, _night.turn_on)


@router.post("/rehearsals/{post_id}/keep-off")
def keep_off(post_id: str):
    """Leave the schedule paused."""
    return card_action(post_id, _night.keep_off)


# Saved sign-ins. The Mac app sends which sites it has (never a password), reads open requests,
# says when it starts typing and how it went. A phone may only say it is the one answering.

def sign_in_store():
    return _sign_ins.Store(home())


def sign_in_private(target):
    try:
        return _private.names(target) | _private.carried_over_names()
    except (OSError, ValueError):
        raise HTTPException(503, "The Private list cannot be read.", headers=NO_STORE) from None


def public_request(record):
    return {k: record.get(k) for k in ("id", "bot", "site", "computer", "focus", "state", "approver", "created_at")}


@router.get("/sign-ins/sites")
def sign_in_sites():
    try:
        return JSONResponse({"sites": sign_in_store().sites()}, headers=NO_STORE)
    except (OSError, ValueError):
        raise HTTPException(503, "The saved sites cannot be read.", headers=NO_STORE) from None


class SignInSites(BaseModel):
    model_config = {"extra": "forbid"}
    sites: list[str]


@router.put("/sign-ins/sites")
def save_sign_in_sites(body: SignInSites):
    try:
        sites = sign_in_store().save_sites(body.sites)
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "The saved sites cannot be written.", headers=NO_STORE) from None
    return JSONResponse({"sites": sites}, headers=NO_STORE)


@router.get("/sign-ins/requests")
def sign_in_requests():
    store = sign_in_store()
    private = sign_in_private(store.root.parent.parent)
    try:
        found = store.open_requests()
    except (OSError, ValueError):
        raise HTTPException(503, "Sign-in requests cannot be read.", headers=NO_STORE) from None
    shown = [public_request(r) for r in found if not _private.excluded(r.get("bot"), private)]
    return JSONResponse({"requests": shown}, headers=NO_STORE)


def sign_in_request(request_id, step):
    store = sign_in_store()
    private = sign_in_private(store.root.parent.parent)
    try:
        record = store.get(request_id)
        if _private.excluded(record.get("bot"), private):
            raise LookupError(request_id)
        record = step(store) if step else record
    except LookupError:
        raise HTTPException(404, "There is no such request.", headers=NO_STORE) from None
    except _sign_ins.Conflict:
        raise HTTPException(409, "This request was already answered or has finished.", headers=NO_STORE) from None
    except ValueError:
        raise HTTPException(422, "That answer is not one Nollie knows.", headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "Sign-in requests cannot be read.", headers=NO_STORE) from None
    return JSONResponse(public_request(record), headers=NO_STORE)


@router.get("/sign-ins/requests/{request_id}")
def get_sign_in_request(request_id: str):
    return sign_in_request(request_id, None)


class SignInClaim(BaseModel):
    model_config = {"extra": "forbid"}
    approver: str


@router.post("/sign-ins/requests/{request_id}/claim")
def claim_sign_in(request_id: str, body: SignInClaim):
    """Which device is answering, before it answers the approval. First one wins."""
    return sign_in_request(request_id, lambda store: store.claim(request_id, body.approver))


@router.post("/sign-ins/requests/{request_id}/start")
def start_sign_in(request_id: str):
    """The Mac is about to type. Only once, and only while the helper still waits."""
    return sign_in_request(request_id, lambda store: store.start(request_id))


class SignInReport(BaseModel):
    model_config = {"extra": "forbid"}
    outcome: str
    reason: str | None = None
    code_note: bool = False


@router.post("/sign-ins/requests/{request_id}/result")
def report_sign_in(request_id: str, body: SignInReport):
    """How it went, in fixed words only: never a username, a password or a note."""
    return sign_in_request(request_id, lambda store: store.report(request_id, body.outcome, body.reason, body.code_note))


@router.get("/sign-ins/history")
def sign_in_history(days: str = "30"):
    if not re.fullmatch(r"[0-9]{1,2}", days) or not 1 <= int(days) <= _sign_ins.KEEP_HISTORY_DAYS:
        raise HTTPException(422, f"Send days from 1 to {_sign_ins.KEEP_HISTORY_DAYS}.", headers=NO_STORE)
    store = sign_in_store()
    private = sign_in_private(store.root.parent.parent)
    try:
        entries = store.history(int(days), private)
    except (OSError, ValueError):
        raise HTTPException(503, "The sign-in history cannot be read.", headers=NO_STORE) from None
    return JSONResponse({"entries": [e for e in entries if not _private.excluded(e.get("bot"), private)]},
                        headers=NO_STORE)


# Calendar, Reminders and Contacts on the Mac. Each helper's switches (read and set from the iPhone too),
# what the Mac says about its own permissions, and the open requests only the Mac answers: it reads, words a
# change, and makes a change only once the tool has the person's yes.

def apple_store():
    return _apple.Store(home())


def apple_private(target):
    try:
        return _private.read(target)[0] | _private.carried_over_names()
    except (OSError, ValueError):
        raise HTTPException(503, "The Private list cannot be read.", headers=NO_STORE) from None


def apple_bot(bot):
    """The store and the bot, once the bot is known and not private."""
    store = apple_store()
    target = store.root.parent.parent
    if not isinstance(bot, str) or not _private.PROFILE_NAME.match(bot):
        raise HTTPException(422, "Send a bot's Hermes profile name.", headers=NO_STORE)
    if _core.private_identity(bot, apple_private(target)):
        raise HTTPException(403, "Calendar, Reminders and Contacts are not used by private bots.", headers=NO_STORE)
    bot_home(bot, target)
    return store


def apple_switches(store, bot):
    try:
        on = store.bots().get(bot, [])
    except (OSError, ValueError):
        raise HTTPException(503, "The switches cannot be read.", headers=NO_STORE) from None
    return JSONResponse({"bot": bot, "on": on, "mac": store.mac()}, headers=NO_STORE)


@router.get("/apple-data/bots")
def apple_data_bot(bot: str = "default"):
    return apple_switches(apple_bot(bot), bot)


class AppleSwitches(BaseModel):
    model_config = {"extra": "forbid"}
    bot: str
    on: list[str]


@router.put("/apple-data/bots")
def save_apple_data_bot(body: AppleSwitches):
    store = apple_bot(body.bot)
    try:
        store.set_bot(body.bot, body.on)
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "The switches cannot be saved.", headers=NO_STORE) from None
    return apple_switches(store, body.bot)


class AppleAccess(BaseModel):
    model_config = {"extra": "forbid"}
    access: dict[str, str]


@router.put("/apple-data/mac")
def save_apple_data_mac(body: AppleAccess):
    """The Mac's own permissions, as it reads them. Only which ones are allowed: nothing from the apps."""
    try:
        access = apple_store().save_mac(body.access)
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "That cannot be saved.", headers=NO_STORE) from None
    return JSONResponse({"access": access}, headers=NO_STORE)


def apple_public(record):
    return {k: record.get(k) for k in ("id", "bot", "tool", "area", "write", "args", "state", "created_at")}


@router.get("/apple-data/requests")
def apple_data_requests():
    store = apple_store()
    private = apple_private(store.root.parent.parent)
    try:
        found = store.open_requests()
        bots = store.bots()
    except (OSError, ValueError):
        raise HTTPException(503, "Requests cannot be read.", headers=NO_STORE) from None
    return JSONResponse({
        "requests": [apple_public(r) for r in found if not _private.excluded(r.get("bot"), private)],
        "bots": {b: on for b, on in bots.items() if not _private.excluded(b, private)},
    }, headers=NO_STORE)


def apple_request(request_id, step):
    store = apple_store()
    private = apple_private(store.root.parent.parent)
    try:
        record = store.get(request_id)
        if _private.excluded(record.get("bot"), private):
            raise LookupError(request_id)
        record = step(store)
    except LookupError:
        raise HTTPException(404, "There is no such request.", headers=NO_STORE) from None
    except _apple.Conflict:
        raise HTTPException(409, "This request has moved on.", headers=NO_STORE) from None
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "Requests cannot be read.", headers=NO_STORE) from None
    return JSONResponse(apple_public(record), headers=NO_STORE)


class AppleCard(BaseModel):
    model_config = {"extra": "forbid"}
    card: str


@router.post("/apple-data/requests/{request_id}/prepare")
def prepare_apple_data(request_id: str, body: AppleCard):
    """The Mac's words for a change it has not made yet. The tool asks the person with exactly these."""
    return apple_request(request_id, lambda store: store.prepare(request_id, body.card))


class AppleAnswer(BaseModel):
    model_config = {"extra": "forbid"}
    result: dict | None = None
    error: str | None = None


@router.post("/apple-data/requests/{request_id}/answer")
def answer_apple_data(request_id: str, body: AppleAnswer):
    return apple_request(request_id, lambda store: store.answer(request_id, body.result, body.error))


# What a helper remembers: its Hermes memory files, to see and change. Moss and every bot named
# private never; another bot on the Private list only for Nollie on the Mac that runs Hermes, which
# says so with ``on_this_mac`` (the Nollie Link door lets nothing but ``bot`` through on these).

def memory_of(bot, on_this_mac=False):
    target = home()
    if not isinstance(bot, str) or not _private.PROFILE_NAME.match(bot):
        raise HTTPException(422, "Send a bot's Hermes profile name.", headers=NO_STORE)
    if _core.private_identity(bot, _private.carried_over_names()):
        raise HTTPException(403, "This bot's memory is never read.", headers=NO_STORE)
    try:
        private = _private.read(target)[0]
    except (OSError, ValueError):
        raise HTTPException(503, "The Private list cannot be read.", headers=NO_STORE) from None
    if _core.private_identity(bot, private) and on_this_mac is not True:
        raise HTTPException(403, "A private bot's memory stays on its Mac.", headers=NO_STORE)
    return _memory.Memory(bot_home(bot, target))


def memory_answer(memory, bot, step=None):
    try:
        if step:
            step(memory)
        return JSONResponse(memory.view(bot), headers=NO_STORE)
    except _memory.Changed:
        raise HTTPException(409, "This changed on your Mac.", headers=NO_STORE) from None
    except _memory.Refused as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except _memory.Busy as exc:
        raise HTTPException(503, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "This memory can't be changed right now.", headers=NO_STORE) from None


@router.get("/memory")
def memory_view(bot: str = "default", on_this_mac: bool = False):
    return memory_answer(memory_of(bot, on_this_mac), bot)


class MemoryNote(BaseModel):
    model_config = {"extra": "forbid"}
    target: str = "user"
    text: str = Field(max_length=8000)


class MemoryEdit(BaseModel):
    model_config = {"extra": "forbid"}
    target: str
    old: str = Field(max_length=300000)
    text: str = Field(max_length=8000)


class MemoryForget(BaseModel):
    model_config = {"extra": "forbid"}
    target: str
    old: str = Field(max_length=300000)


class MemorySwitch(BaseModel):
    model_config = {"extra": "forbid"}
    on: bool


@router.post("/memory/notes")
def memory_add(body: MemoryNote, bot: str = "default", on_this_mac: bool = False):
    return memory_answer(memory_of(bot, on_this_mac), bot, lambda m: m.add(body.target, body.text))


@router.put("/memory/notes")
def memory_edit(body: MemoryEdit, bot: str = "default", on_this_mac: bool = False):
    return memory_answer(memory_of(bot, on_this_mac), bot, lambda m: m.edit(body.target, body.old, body.text))


@router.delete("/memory/notes")
def memory_forget(body: MemoryForget, bot: str = "default", on_this_mac: bool = False):
    return memory_answer(memory_of(bot, on_this_mac), bot, lambda m: m.forget(body.target, body.old))


@router.put("/memory/switch")
def memory_switch(body: MemorySwitch, bot: str = "default", on_this_mac: bool = False):
    memory = memory_of(bot, on_this_mac)
    try:
        memory.set_on(body.on)
    except Exception:
        raise HTTPException(503, "That can't be changed right now.", headers=NO_STORE) from None
    return memory_answer(memory, bot)


# Paying with saved cards. The Mac app sends its cards as labels (never a number), reads open requests, words each
# card by its own rules or refuses it, says when it starts typing, how it went and when the number has gone from the
# screen. A phone may read the labels and a helper's switch, and change the switch.

def payment_store():
    return _payments.Store(home())


def payment_bot(bot):
    """The store and the bot, once the bot is known and not private."""
    store = payment_store()
    target = store.root.parent.parent
    if not isinstance(bot, str) or not _private.PROFILE_NAME.match(bot):
        raise HTTPException(422, "Send a bot's Hermes profile name.", headers=NO_STORE)
    if _core.private_identity(bot, apple_private(target)):
        raise HTTPException(403, "Private bots never pay.", headers=NO_STORE)
    bot_home(bot, target)
    return store


@router.get("/payments/cards")
def payment_cards():
    try:
        cards = payment_store().cards()
    except (OSError, ValueError):
        raise HTTPException(503, "The cards cannot be read.", headers=NO_STORE) from None
    return JSONResponse({"cards": cards}, headers=NO_STORE)


class PaymentCards(BaseModel):
    model_config = {"extra": "forbid"}
    cards: list[dict]


@router.put("/payments/cards")
def save_payment_cards(body: PaymentCards):
    """Labels only: brand, last four digits and the name on the card."""
    try:
        cards = payment_store().save_cards(body.cards)
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "The cards cannot be written.", headers=NO_STORE) from None
    return JSONResponse({"cards": cards}, headers=NO_STORE)


def payment_switch(store, bot):
    try:
        on = bot in store.bots()
    except (OSError, ValueError):
        raise HTTPException(503, "The switch cannot be read.", headers=NO_STORE) from None
    return JSONResponse({"bot": bot, "on": on}, headers=NO_STORE)


@router.get("/payments/bots")
def payment_bot_switch(bot: str = "default"):
    return payment_switch(payment_bot(bot), bot)


class PaymentSwitch(BaseModel):
    model_config = {"extra": "forbid"}
    bot: str
    on: bool


@router.put("/payments/bots")
def save_payment_bot_switch(body: PaymentSwitch):
    store = payment_bot(body.bot)
    try:
        store.set_bot(body.bot, body.on)
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "The switch cannot be saved.", headers=NO_STORE) from None
    return payment_switch(store, body.bot)


def payment_public(record):
    return {k: record.get(k) for k in ("id", "bot", "site", "total", "currency", "card", "computer", "state", "ask",
                                       "approver", "created_at")}


@router.get("/payments/requests")
def payment_requests():
    store = payment_store()
    private = apple_private(store.root.parent.parent)
    try:
        found = store.open_requests()
        bots = store.bots()
    except (OSError, ValueError):
        raise HTTPException(503, "Payments cannot be read.", headers=NO_STORE) from None
    return JSONResponse({
        "requests": [payment_public(r) for r in found if not _private.excluded(r.get("bot"), private)],
        "bots": [b for b in bots if not _private.excluded(b, private)],
    }, headers=NO_STORE)


def payment_request(request_id, step):
    store = payment_store()
    private = apple_private(store.root.parent.parent)
    try:
        record = store.get(request_id)
        if _private.excluded(record.get("bot"), private):
            raise LookupError(request_id)
        record = step(store) if step else record
    except LookupError:
        raise HTTPException(404, "There is no such request.", headers=NO_STORE) from None
    except _payments.Conflict:
        raise HTTPException(409, "This payment has moved on.", headers=NO_STORE) from None
    except ValueError as exc:
        raise HTTPException(422, str(exc), headers=NO_STORE) from None
    except OSError:
        raise HTTPException(503, "Payments cannot be read.", headers=NO_STORE) from None
    return JSONResponse(payment_public(record), headers=NO_STORE)


@router.get("/payments/requests/{request_id}")
def get_payment_request(request_id: str):
    return payment_request(request_id, None)


class PaymentWords(BaseModel):
    model_config = {"extra": "forbid"}
    words: str
    card: str
    ask: bool


@router.post("/payments/requests/{request_id}/prepare")
def prepare_payment(request_id: str, body: PaymentWords):
    """The Mac's words for the card, the card it will use, and whether its rules ask the person."""
    return payment_request(request_id, lambda store: store.prepare(request_id, body.words, body.card, body.ask))


class PaymentRefusal(BaseModel):
    model_config = {"extra": "forbid"}
    reason: str
    expected: str | None = None


@router.post("/payments/requests/{request_id}/refuse")
def refuse_payment(request_id: str, body: PaymentRefusal):
    return payment_request(request_id, lambda store: store.refuse(request_id, body.reason, body.expected))


@router.post("/payments/requests/{request_id}/start")
def start_payment(request_id: str):
    """The Mac is about to type. Only once, and only while the helper still waits."""
    return payment_request(request_id, lambda store: store.start(request_id))


class PaymentReport(BaseModel):
    model_config = {"extra": "forbid"}
    outcome: str
    reason: str | None = None
    showing: bool = False


@router.post("/payments/requests/{request_id}/result")
def report_payment(request_id: str, body: PaymentReport):
    """How it went, in fixed words only: never a card number."""
    return payment_request(request_id, lambda store: store.report(request_id, body.outcome, body.reason, body.showing))


@router.post("/payments/requests/{request_id}/clear")
def clear_payment(request_id: str):
    """The card number has gone from the screen."""
    return payment_request(request_id, lambda store: store.clear(request_id))


@router.get("/payments/history")
def payment_history(days: str = "30"):
    if not re.fullmatch(r"[0-9]{1,2}", days) or not 1 <= int(days) <= _payments.KEEP_HISTORY_DAYS:
        raise HTTPException(422, f"Send days from 1 to {_payments.KEEP_HISTORY_DAYS}.", headers=NO_STORE)
    store = payment_store()
    private = apple_private(store.root.parent.parent)
    try:
        entries = store.history(int(days), private)
    except (OSError, ValueError):
        raise HTTPException(503, "The payment history cannot be read.", headers=NO_STORE) from None
    return JSONResponse({"entries": [e for e in entries if not _private.excluded(e.get("bot"), private)]},
                        headers=NO_STORE)
