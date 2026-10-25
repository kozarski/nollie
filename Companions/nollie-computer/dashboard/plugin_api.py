"""Mounted by Hermes under its authenticated /api/plugins/nollie-computer namespace."""
import importlib.util
import asyncio
import atexit
from pathlib import Path

from fastapi import APIRouter, Body, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, StrictBool


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_core = _load("nollie_computer_preview", "preview_core.py")
_takeover = _load("nollie_computer_takeover", "takeover_core.py")
_control = _takeover.ControlService(private_reader=_core.private_names)
_service = _core.PreviewService(control_reader=_control.control)
_own = _load("nollie_computer_own", "own_computer.py")
_computers = _own.OwnComputers(private=lambda profile: profile.lower() in _core.private_names())
_ask_first = _load("nollie_computer_ask_first", "ask_first.py")
_ask_first_service = _ask_first.AskFirst(_core.main_home, _core.private_names)
# Cua children kept between pictures go when Hermes stops, or at exit if it never says so.
router = APIRouter(on_shutdown=[_service.close])
atexit.register(_service.pool.kill)
NO_STORE = {"Cache-Control": "no-store", "Pragma": "no-cache"}


@router.get("/preview")
async def preview(profile: str = Query(..., max_length=160), session_id: str = Query(..., max_length=160),
                  fresh: bool = Query(False)):
    """fresh=1 skips the short cache, for a caller that wants each next picture."""
    try:
        result = await asyncio.wait_for(_service.preview(profile, session_id, fresh=fresh), 7.0)
    except TimeoutError:
        result = {"state": "unavailable", "message": "The computer preview is unavailable right now."}
    return JSONResponse(result, headers=NO_STORE)


@router.get("/paused")
async def paused():
    """Whether pictures of every computer are paused for a saved sign-in, by the preview's own rule.
    Nollie's live picture of a window on this Mac asks this before and while it captures."""
    return JSONResponse({"paused": await asyncio.to_thread(_service.typing)}, headers=NO_STORE)


async def _change(action, profile):
    try:
        result = await asyncio.to_thread(action, profile)
        return JSONResponse(result, headers=NO_STORE)
    except Exception:
        # Private bots, unknown bots and unreadable leases all get the same answer.
        return JSONResponse({"detail": "This computer can't be taken over right now."},
                            status_code=409, headers=NO_STORE)


@router.post("/take-over")
async def take_over(profile: str = Query(..., max_length=160)):
    return await _change(_control.take_over, profile)


@router.post("/hand-back")
async def hand_back(profile: str = Query(..., max_length=160)):
    return await _change(_control.hand_back, profile)


async def _answer(work):
    try:
        result = await asyncio.wait_for(asyncio.to_thread(work), 45.0)
    except _own.Refused as refusal:
        return JSONResponse({"detail": str(refusal)}, status_code=refusal.status, headers=NO_STORE)
    except TimeoutError:
        return JSONResponse({"detail": "Your Mac didn't answer in time."}, status_code=504, headers=NO_STORE)
    return JSONResponse(result, headers=NO_STORE)


@router.get("/own-computer")
async def own_computer(profile: str = Query(..., max_length=64)):
    """A helper's own computer: the switch, what Cua still needs, and how the computer is."""
    return await _answer(lambda: _computers.status(profile))


@router.post("/own-computer")
async def change_own_computer(body: dict = Body(...)):
    """Starts one change (on, off, reset, remove) and answers at once with the status."""
    return await _answer(lambda: _computers.change(body.get("profile"), body.get("action"), body.get("request_id")))


class AskFirstChange(BaseModel):
    model_config = {"extra": "forbid"}
    enabled: StrictBool


async def _ask_first_answer(work):
    try:
        result = await asyncio.to_thread(work)
        return JSONResponse(result, headers=NO_STORE)
    except _ask_first.Refused as refusal:
        return JSONResponse({"detail": str(refusal)}, status_code=refusal.status, headers=NO_STORE)


@router.get("/ask-first")
async def ask_first(profile: str = Query(..., max_length=64)):
    return await _ask_first_answer(lambda: _ask_first_service.status(profile))


@router.put("/ask-first")
async def change_ask_first(body: AskFirstChange, profile: str = Query(..., max_length=64)):
    return await _ask_first_answer(lambda: _ask_first_service.change(profile, body.enabled))
