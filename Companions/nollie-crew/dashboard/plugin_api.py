"""The app's buttons: Add or Not now on a suggestion card, and Undo on a crew note.

Hermes authenticates this namespace. These answers come from the person's own tap in the app,
never from a model, and only for Nollie's profile.
"""
import importlib.util
from pathlib import Path
import sys

from fastapi import APIRouter, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

_name = "nollie_crew_dashboard"
_root = Path(__file__).resolve().parent.parent
if _name not in sys.modules:
    _spec = importlib.util.spec_from_file_location(_name, _root / "__init__.py",
                                                 submodule_search_locations=[str(_root)])
    _module = importlib.util.module_from_spec(_spec)
    sys.modules[_name] = _module
    _spec.loader.exec_module(_module)
_crew = __import__(_name + ".crew", fromlist=["Crew"])
_profiles = __import__(_name + ".hermes_profiles", fromlist=["HermesProfiles"])
router = APIRouter()


def crew():
    from hermes_cli.profiles import get_active_profile_name
    if get_active_profile_name() != "default":
        raise HTTPException(403, "The crew belongs to Nollie.")
    profiles = _profiles.HermesProfiles()
    return _crew.Crew(profiles, profiles.home("default") / "nollie-crew")


def reply(result):
    status = 200 if result.get("ok") else 409
    return JSONResponse(result, status_code=status, headers={"Cache-Control": "no-store"})


@router.get("/crew")
def crew_list():
    try:
        return reply(crew().list())
    except ValueError:
        raise HTTPException(503, "The crew record needs repair.") from None


class Answer(BaseModel):
    answer: str


@router.post("/suggestions/{key}")
def answer(key: str, body: Answer):
    if body.answer not in ("add", "not_now"):
        raise HTTPException(400, "Answer with add or not_now.")
    return reply(crew().answer_suggestion(key, body.answer))


class Undo(BaseModel):
    token: str


@router.post("/undo")
def undo(body: Undo):
    return reply(crew().undo(body.token))
