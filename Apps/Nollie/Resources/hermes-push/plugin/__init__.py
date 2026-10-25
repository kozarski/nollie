"""Nollie push packaged as a Hermes plugin.

The relay from hermes_push.py runs on a background thread within Hermes, so there is no
service to set up. The app writes its settings to hermes-push.conf in the push folder under HERMES_HOME.
"""
from __future__ import annotations

import asyncio
import importlib
import logging
import sys
import threading
import time
from pathlib import Path

log = logging.getLogger("nollie-push")

_unloading = threading.Event()
_lock_file = None


def _take_the_lock(push) -> bool:
    """Plugins get loaded by more than one Hermes process (dashboard, gateway), and two live relays
    would deliver each notification twice, so only the holder of the lock runs. Others wait their
    turn: after a restart the previous process may keep the lock for a few seconds."""
    global _lock_file
    try:
        import fcntl
    except ImportError:          # no advisory locks on this platform: just run
        return True
    path = push.status_path().with_name("relay.lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    _lock_file = open(path, "w")
    told = False
    while not _unloading.is_set():
        try:
            fcntl.flock(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if not told:
                log.info("another Hermes process runs the relay; waiting for it to stop")
                told = True
            time.sleep(5)
            continue
        if told:
            log.info("got the relay lock; starting")
        return True
    return False


def _work() -> None:
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import hermes_push as push
        push._load_conf()
        if not _take_the_lock(push):
            return
        while not _unloading.is_set():
            try:
                asyncio.run(push.Relay().run())
                return
            except push.CodeChanged:
                # A fresher hermes_push.py appeared beside this file; reload it so Hermes needs no restart.
                log.info("loading the updated hermes_push.py")
                push = importlib.reload(push)
                push._CONF.clear()
                push._load_conf()
    except SystemExit as why:
        log.warning("push relay not started: %s", why)
    except Exception:  # noqa: BLE001
        log.exception("push relay stopped")


def register(ctx) -> None:
    threading.Thread(target=_work, name="nollie-push", daemon=True).start()
    try:
        ctx.on_unload(_unloading.set)
    except Exception:  # noqa: BLE001
        pass
    log.info("push plugin started")
