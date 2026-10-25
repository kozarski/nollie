"""One background observer per default Hermes home."""
import logging
import threading

from .workflow_core import Engine, atomic_write, file_lock, read_state
from .hermes_adapter import BoardSource, BotChatDelivery, default_scope
from .followup_tools import manager
from .night_shift import OutcomeLog
from .night_service import NightService, wait_for_wake

log = logging.getLogger("nollie-workflow")


def run(home, stop):
    root = home / "nollie-workflow"
    engine = Engine(root, BoardSource(home), BotChatDelivery(home), should_stop=stop.is_set,
                    followups=manager(home), outcome_log=OutcomeLog(root).add)
    night = NightService(home)
    while not stop.is_set():
        try:
            with file_lock(root / "service.lock", blocking=False):
                while not stop.is_set():
                    try:
                        with default_scope(home):
                            engine.tick()
                    except Exception as exc:
                        # Status and logs contain failure type only, never task or credential text.
                        with file_lock(root / "state.lock"):
                            state = read_state(root)
                            state["last_error"] = type(exc).__name__
                            atomic_write(root / "state.json", state)
                        log.warning("Board follow-through poll failed: %s", type(exc).__name__)
                    try:
                        night.tick()
                        night.note()
                    except Exception as exc:
                        log.warning("Night shift tick failed: %s", type(exc).__name__)
                        try:
                            night.note(type(exc).__name__)
                        except Exception:
                            pass
                    wait_for_wake(root, stop, 15)
        except BlockingIOError:
            stop.wait(5)


def start(home, ctx):
    stop = threading.Event()
    thread = threading.Thread(target=run, args=(home, stop), name="nollie-workflow", daemon=True)
    ctx.on_unload(stop.set)
    thread.start()
