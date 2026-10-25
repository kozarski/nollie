"""All routes remain inside Hermes's authenticated plugin namespace."""
import hashlib

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from hermes_cli.dashboard_auth import get_provider, ProviderError

router = APIRouter()
_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache"}


def _provider(request):
    if not getattr(request.app.state, "auth_required", False):
        return None, "authenticated_https_required"
    if request.url.scheme != "https":
        return None, "https_required"
    provider = get_provider("nollie-pairing")
    if provider is None or not provider._active():
        return None, "companion_required"
    return provider, None


def _owner(request):
    # Native credential headers only: a cross-site form cannot authorize enrollment.
    session = getattr(request.state, "session", None)
    bearer = request.headers.get("authorization", "")
    if session is None or not bearer.lower().startswith("bearer ") or not bearer[7:].strip():
        raise HTTPException(401, "Sign in on this Mac first.")
    if session.provider == "nollie-pairing":
        raise HTTPException(403, "Create pairing codes from the original Mac connection.")
    return hashlib.sha256((session.provider + "\x00" + session.org_id + "\x00" + session.user_id).encode()).hexdigest()


def _ready(request):
    owner = _owner(request)
    provider, _ = _provider(request)
    if provider is None:
        raise HTTPException(409, "Pairing needs an authenticated HTTPS connection.")
    return provider, owner


def _reply(value):
    return JSONResponse(value, headers=_HEADERS)


def _call(operation):
    try:
        return operation()
    except KeyError:
        raise HTTPException(404, "Pairing item unavailable.") from None
    except OverflowError:
        raise HTTPException(429, "Too many pairing requests. Try again later.") from None
    except ValueError:
        raise HTTPException(400, "Invalid pairing request.") from None
    except ProviderError:
        raise HTTPException(503, "Pairing is unavailable right now.") from None


@router.get("/capabilities")
def capabilities(request: Request):
    _, reason = _provider(request)
    if reason is None:
        try:
            _owner(request)
        except HTTPException:
            reason = "original_sign_in_required"
    return _reply({"supported": reason is None, "reason": reason})


class CreateInvitation(BaseModel):
    device_name: str = Field(default="iPhone", min_length=1, max_length=64)


@router.post("/invitations")
def create(request: Request, body: CreateInvitation):
    provider, owner = _ready(request)
    return _reply(_call(lambda: provider.create_invitation(owner, body.device_name)))


@router.get("/invitations/{invitation_id}")
def status(request: Request, invitation_id: str):
    provider, owner = _ready(request)
    return _reply(_call(lambda: provider.invitation_status(owner, invitation_id)))


@router.delete("/invitations/{invitation_id}")
def cancel(request: Request, invitation_id: str):
    provider, owner = _ready(request)
    _call(lambda: provider.cancel_invitation(owner, invitation_id))
    return _reply({"ok": True})


@router.get("/devices")
def devices(request: Request):
    provider, owner = _ready(request)
    return _reply({"devices": _call(lambda: provider.list_devices(owner))})


@router.delete("/devices/{device_id}")
def revoke(request: Request, device_id: str):
    provider, owner = _ready(request)
    _call(lambda: provider.revoke_device(owner, device_id))
    return _reply({"ok": True})


@router.delete("/device")
def revoke_self(request: Request):
    provider, _ = _provider(request)
    session = getattr(request.state, "session", None)
    bearer = request.headers.get("authorization", "")
    if provider is None or session is None or session.provider != "nollie-pairing" or not bearer.lower().startswith("bearer "):
        raise HTTPException(401, "A paired device sign-in is required.")
    prefix = "nollie-device:"
    if not session.user_id.startswith(prefix):
        raise HTTPException(401, "A paired device sign-in is required.")
    _call(lambda: provider.revoke_current_device(session.user_id[len(prefix):]))
    return _reply({"ok": True})
