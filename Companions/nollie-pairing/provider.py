"""Independent device credentials; invitation secrets exist only in memory as hashes."""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time
import uuid

from hermes_cli.dashboard_auth import (
    DashboardAuthProvider, InvalidCodeError, InvalidCredentialsError, LoginStart,
    ProviderError, RefreshExpiredError, Session,
)

INVITATION_TTL = 120
ACCESS_TTL = 15 * 60
REFRESH_TTL = 180 * 24 * 60 * 60
MAX_DEVICES = 32
MAX_INVITATIONS = 8
_TOKEN = re.compile(r"^[0-9a-f]{64}$")
_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _name(value: str) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= 64 or value != value.strip():
        raise ValueError("invalid device name")
    if any(ord(c) < 32 or 127 <= ord(c) < 160 or c in "\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069" for c in value):
        raise ValueError("invalid device name")
    return value


class PairingProvider(DashboardAuthProvider):
    name = "nollie-pairing"
    display_name = "Pair with Nollie on your Mac"
    supports_password = True
    supports_session = True

    def __init__(self, root: Path, *, clock=time.time, monotonic=time.monotonic, enabled=lambda: True):
        self.root = Path(root)
        self.clock = clock
        self.monotonic = monotonic
        self.enabled = enabled
        self.lock = threading.RLock()
        self.invitations = {}
        self.attempts = []
        self.creates = []
        # No state or credentials are read until an explicit pairing/auth request.

    def _active(self):
        try:
            return bool(self.enabled())
        except Exception:
            return False

    def start_login(self, *, redirect_uri: str) -> LoginStart:
        raise InvalidCodeError("Create a pairing code in Nollie on your Mac.")

    def complete_login(self, *, code: str, state: str, code_verifier: str, redirect_uri: str) -> Session:
        raise InvalidCodeError("Use a pairing code.")

    def _gc(self, now):
        self.invitations = {k: v for k, v in self.invitations.items() if now < v["expires_at"] + 600}
        for item in self.invitations.values():
            if item["state"] == "pending" and (now >= item["expires_at"] or self.monotonic() >= item["deadline"]):
                item["state"] = "expired"
                item.pop("grant_hash", None)
        self.attempts = [t for t in self.attempts if now - t < 60]
        self.creates = [t for t in self.creates if now - t < 3600]

    def create_invitation(self, owner: str, device_name: str):
        if not self._active():
            raise ValueError("pairing unavailable")
        device_name = _name(device_name)
        with self.lock:
            now = int(self.clock())
            self._gc(now)
            if len(self.creates) >= 20 or sum(v["state"] == "pending" for v in self.invitations.values()) >= MAX_INVITATIONS:
                raise OverflowError("pairing limit reached")
            with self._state() as state:
                self._prune_devices(state, now)
                if len(state["devices"]) >= MAX_DEVICES:
                    raise OverflowError("device limit reached")
            invitation_id = str(uuid.uuid4())
            grant = secrets.token_hex(32)
            self.invitations[invitation_id] = {
                "owner": owner, "name": device_name, "grant_hash": _hash(grant),
                "expires_at": now + INVITATION_TTL, "state": "pending", "attempts": 0,
                "deadline": self.monotonic() + INVITATION_TTL,
            }
            self.creates.append(now)
            return {"id": invitation_id, "grant": grant, "expires_at": now + INVITATION_TTL}

    def invitation_status(self, owner: str, invitation_id: str):
        with self.lock:
            self._gc(int(self.clock()))
            item = self.invitations.get(invitation_id)
            if item is None or not hmac.compare_digest(item["owner"], owner):
                raise KeyError("invitation unavailable")
            return {"state": item["state"]}

    def cancel_invitation(self, owner: str, invitation_id: str):
        with self.lock:
            self.invitation_status(owner, invitation_id)
            item = self.invitations[invitation_id]
            if item["state"] == "pending":
                item["state"] = "cancelled"
                item.pop("grant_hash", None)
            # Closing the Mac sheet after success must not revoke the paired phone.

    def complete_password_login(self, *, username: str, password: str) -> Session:
        if not self._active():
            raise InvalidCredentialsError("Invalid or expired pairing code.")
        with self.lock:
            now = int(self.clock())
            self._gc(now)
            if len(self.attempts) >= 60:
                raise InvalidCredentialsError("Invalid or expired pairing code.")
            self.attempts.append(now)
            item = self.invitations.get(username) if isinstance(username, str) and _ID.fullmatch(username) else None
            valid_shape = isinstance(password, str) and _TOKEN.fullmatch(password) is not None
            actual = _hash(password) if valid_shape else "0" * 64
            expected = item.get("grant_hash", "0" * 64) if item else "0" * 64
            matches = hmac.compare_digest(actual, expected)
            if item is None or item["state"] != "pending" or not valid_shape or not matches:
                if item is not None and item["state"] == "pending":
                    item["attempts"] += 1
                    if item["attempts"] >= 5:
                        item["state"] = "cancelled"
                        item.pop("grant_hash", None)
                raise InvalidCredentialsError("Invalid or expired pairing code.")
            # Consume before any durable operation. An uncertain save cannot replay the grant.
            item["state"] = "cancelled"
            item.pop("grant_hash", None)
            with self._state() as state:
                self._prune_devices(state, now)
                if len(state["devices"]) >= MAX_DEVICES:
                    raise ProviderError("Pairing storage unavailable.")
                session, device = self._mint(username, item["owner"], item["name"], now)
                state["devices"][username] = device
                self._save(state)
            item["state"] = "paired"
            return session

    def verify_session(self, *, access_token: str):
        if not self._active() or not isinstance(access_token, str) or not _TOKEN.fullmatch(access_token):
            return None
        digest = _hash(access_token)
        now = int(self.clock())
        with self._state() as state:
            for device_id, device in state["devices"].items():
                if hmac.compare_digest(device["access_hash"], digest) and now < device["access_expires_at"]:
                    return self._session(device_id, device["access_expires_at"], access_token, "")
        return None

    def refresh_session(self, *, refresh_token: str):
        if not self._active() or not isinstance(refresh_token, str) or not _TOKEN.fullmatch(refresh_token):
            raise RefreshExpiredError("Pair this device again.")
        digest = _hash(refresh_token)
        now = int(self.clock())
        with self._state() as state:
            for device_id, device in state["devices"].items():
                if hmac.compare_digest(device["refresh_hash"], digest) and now < device["refresh_expires_at"]:
                    session, replacement = self._mint(device_id, device["owner"], device["name"], now)
                    replacement["created_at"] = device["created_at"]
                    state["devices"][device_id] = replacement
                    self._save(state)
                    return session
        raise RefreshExpiredError("Pair this device again.")

    def revoke_session(self, *, refresh_token: str):
        if not isinstance(refresh_token, str) or not _TOKEN.fullmatch(refresh_token):
            return
        digest = _hash(refresh_token)
        try:
            with self._state() as state:
                state["devices"] = {k: v for k, v in state["devices"].items() if not hmac.compare_digest(v["refresh_hash"], digest)}
                self._save(state)
        except ProviderError:
            return  # Hermes's provider contract makes logout best-effort.

    def list_devices(self, owner: str):
        with self._state() as state:
            now = int(self.clock())
            return [{"id": k, "name": v["name"], "created_at": v["created_at"]}
                    for k, v in state["devices"].items()
                    if hmac.compare_digest(v["owner"], owner) and now < v["refresh_expires_at"]]

    def revoke_device(self, owner: str, device_id: str):
        with self._state() as state:
            device = state["devices"].get(device_id)
            if device is None or not hmac.compare_digest(device["owner"], owner):
                raise KeyError("device unavailable")
            del state["devices"][device_id]
            self._save(state)

    def revoke_current_device(self, device_id: str):
        if not isinstance(device_id, str) or not _ID.fullmatch(device_id):
            raise KeyError("device unavailable")
        with self._state() as state:
            state["devices"].pop(device_id, None)
            self._save(state)

    def _mint(self, device_id, owner, name, now):
        access, refresh = secrets.token_hex(32), secrets.token_hex(32)
        device = {"owner": owner, "name": name, "created_at": now,
                  "access_hash": _hash(access), "refresh_hash": _hash(refresh),
                  "access_expires_at": now + ACCESS_TTL, "refresh_expires_at": now + REFRESH_TTL}
        return self._session(device_id, now + ACCESS_TTL, access, refresh), device

    def _session(self, device_id, expires_at, access, refresh):
        return Session(user_id="nollie-device:" + device_id, email="", display_name="Paired iPhone",
                       org_id="", provider=self.name, expires_at=expires_at,
                       access_token=access, refresh_token=refresh)

    def _prune_devices(self, state, now):
        state["devices"] = {k: v for k, v in state["devices"].items() if now < v["refresh_expires_at"]}

    def _check_file(self, fd):
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("unsafe pairing storage")

    @contextlib.contextmanager
    def _state(self):
        with self.lock:
            fd = None
            try:
                self.root.mkdir(mode=0o700, parents=False, exist_ok=True)
                info = self.root.lstat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                    raise ValueError("unsafe pairing storage")
                fd = os.open(self.root / "devices.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                self._check_file(fd)
                fcntl.flock(fd, fcntl.LOCK_EX)
                value = self._read()
            except (OSError, ValueError, TypeError, KeyError, AttributeError):
                if fd is not None:
                    os.close(fd)
                raise ProviderError("Pairing storage unavailable.") from None
            try:
                yield value
            except OSError:
                raise ProviderError("Pairing storage unavailable.") from None
            finally:
                os.close(fd)

    def _read(self):
        try:
            fd = os.open(self.root / "devices.json", os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return {"version": 1, "devices": {}}
        with os.fdopen(fd, "rb") as handle:
            self._check_file(handle.fileno())
            data = handle.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("oversized pairing storage")
        value = json.loads(data)
        if value.get("version") != 1 or not isinstance(value.get("devices"), dict) or len(value["devices"]) > MAX_DEVICES:
            raise ValueError("invalid pairing storage")
        fields = {"owner", "name", "created_at", "access_hash", "refresh_hash", "access_expires_at", "refresh_expires_at"}
        for key, device in value["devices"].items():
            if not _ID.fullmatch(key) or not isinstance(device, dict) or set(device) != fields:
                raise ValueError("invalid pairing storage")
            _name(device["name"])
            if not all(isinstance(device[f], str) and _TOKEN.fullmatch(device[f]) for f in ("owner", "access_hash", "refresh_hash")):
                raise ValueError("invalid pairing storage")
            if not all(type(device[f]) is int and device[f] > 0 for f in ("created_at", "access_expires_at", "refresh_expires_at")):
                raise ValueError("invalid pairing storage")
        return value

    def _save(self, state):
        path = self.root / (".devices-" + secrets.token_hex(12))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(json.dumps(state, separators=(",", ":")).encode())
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(path, self.root / "devices.json")
            directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            path.unlink(missing_ok=True)
