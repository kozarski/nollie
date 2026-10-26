#!/usr/bin/env python3
"""Nollie push companion.

Run it beside Hermes and it keeps a websocket open to the gateway, as one more client among the
rest. Whenever someone has to step in (to approve, to answer, to read a reply, to look at a failure
or a finished cron job), each phone, Mac and watch found in <HERMES_HOME>/push/devices/ is notified.
Phones also get a Live Activity that follows the turn while it runs.

Settings live in the KEY=VALUE file at HERMES_PUSH_CONFIG (default: hermes-push.conf in HERMES_HOME's push folder),
which the app writes. An environment variable of the same name overrides the file. Every key begins
with HERMES_PUSH_:
  GATEWAY_URL, PUBLIC_URL, GATEWAY_TOKEN, GATEWAY_BEARER, GATEWAY_REFRESH_TOKEN,
  CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET,
  APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, APNS_SANDBOX,
  DEVICES_DIR, POLL_SECONDS, RELEASE_IDLE_SECONDS,
  FINISH_EXPAND, FINISH_ISLAND, FINISH_LINGER.

Needs websockets, PyJWT and cryptography. The Hermes virtualenv ships all of them.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import glob
import hashlib
import json
import logging
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

try:
    import jwt
    import websockets
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError as missing:  # pragma: no cover
    sys.exit(f"missing dependency: {missing}. Use the Hermes venv python, or: pip install websockets pyjwt cryptography")

log = logging.getLogger("hermes-push")

# Must equal the version in plugin/nollie-push/plugin.yaml, because the app shows them together.
VERSION = "1.0.43"
USER_AGENT = f"Nollie-Push/{VERSION} (companion for Hermes)"

HOUR = 3600
LA_MAX_AGE = 8 * HOUR          # iOS closes a Live Activity by itself after about this long
MARKER_LIFETIME = {"origins": 12 * HOUR, "goals": LA_MAX_AGE, "answers": HOUR}
PHASE_WORDS = {"thinking": "Thinking…", "streaming": "Writing…", "tool": "Running a tool…"}
QUIET_STATUSES = frozenset({"idle", "", "done", "finished"})


def _own_digest():
    try:
        return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    except OSError:
        return ""


# Hash of this very script. The app checks it against the bundled copy, so an update still shows
# as pending when the gateway was never restarted and VERSION stayed put.
SCRIPT_SHA256 = _own_digest()


def code_changed():
    current = _own_digest()
    return current != "" and current != SCRIPT_SHA256


def _is_busy(status):
    return (status or "idle") not in QUIET_STATUSES


# ───────────────────────────────── settings ─────────────────────────────────

_CONF: dict[str, str] = {}
_CONF_PATH: Path | None = None
_ASSIGNMENT = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def _hermes_home():
    return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))


def _config_files():
    chosen = os.environ.get("HERMES_PUSH_CONFIG", "").strip()
    if chosen:
        yield Path(chosen).expanduser()
    yield _hermes_home() / "push" / "hermes-push.conf"


def _load_conf():
    """Read the first settings file that exists into _CONF."""
    global _CONF_PATH
    path = next((p for p in _config_files() if p.is_file()), None)
    if path is None:
        return
    _CONF_PATH = path
    for raw in path.read_text(encoding="utf-8").splitlines():
        hit = None if raw.lstrip().startswith("#") else _ASSIGNMENT.match(raw)
        if hit:
            _CONF[hit.group(1)] = hit.group(2).strip().strip("\"'")


def env(key, fallback=""):
    """A setting: the real environment first, then the settings file, then the fallback."""
    for table in (os.environ, _CONF):
        if table.get(key):
            return table[key].strip()
    return fallback.strip()


def flag(name):
    return env(name).lower() in ("1", "true", "yes")


def save_conf_value(name, value):
    """Put a renewed credential into the settings file so the next start has it."""
    if _CONF_PATH is None:
        return
    kept = []
    for raw in _CONF_PATH.read_text(encoding="utf-8").splitlines():
        hit = _ASSIGNMENT.match(raw)
        if not (hit and hit.group(1) == name):
            kept.append(raw)
    kept.append(f"{name}={value}")
    _CONF_PATH.write_text("\n".join(kept) + "\n", encoding="utf-8")
    _CONF[name] = value


def conf_mtime():
    try:
        return _CONF_PATH.stat().st_mtime if _CONF_PATH else 0.0
    except OSError:
        return 0.0


def seconds_setting(name, fallback):
    try:
        return max(0, int(float(env(name) or fallback)))
    except ValueError:
        return fallback


# ─────────────────────────────── silent replies ─────────────────────────────

CONTROL_WORDS = frozenset({"[SILENT]", "NO_REPLY"})
FAILURE_FINISHES = frozenset({"error", "failed", "interrupted", "cancelled"})


def is_silent_result(text):
    """True only when the whole text is a control word, not when a sentence mentions one."""
    return isinstance(text, str) and text.strip() in CONTROL_WORDS


def _dig(record, *path):
    """Follow dictionary keys; None as soon as something on the way is not a dictionary."""
    for key in path:
        record = record.get(key) if isinstance(record, dict) else None
    return record


def _went_well(record):
    # Gateways that predate "status" send none; anything but "complete" or an error means it failed.
    return not record.get("error") and record.get("status") in (None, "", "complete")


def is_silent_completion(payload, *, automated=False):
    if not _went_well(payload):
        return False
    if automated and is_silent_result(payload.get("text")):
        return True
    return payload.get("intentional_silence") is True and payload.get("status") == "complete"


def is_silent_message(message):
    """The same decision for a message read back from a stored session."""
    if not _went_well(message) or message.get("finish_reason") in FAILURE_FINISHES:
        return False
    quiet_row = message.get("display_kind") == "hidden" and _dig(message, "display_metadata", "control_marker")
    return quiet_row == "intentional_silence" or is_silent_result(message.get("text"))


# ────────────────────────────── files and folders ───────────────────────────


def devices_dir():
    override = env("HERMES_PUSH_DEVICES_DIR")
    if override:
        return Path(override).expanduser()
    configured = env("HERMES_HOME")
    return (Path(configured) if configured else Path.home() / ".hermes") / "push" / "devices"


def push_dir():
    return devices_dir().parent


def status_path():
    return push_dir() / "status.json"


def _json_or_none(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def _clear_old_files(folder, lifetime):
    limit = time.time() - lifetime
    for name in glob.glob(str(folder / "*.json")):
        try:
            if os.path.getmtime(name) < limit:
                os.remove(name)
        except OSError:
            continue


def write_status(**fields):
    """The heartbeat the app reads to see that the companion lives, and which code is running."""
    beat = dict(version=VERSION, script_sha256=SCRIPT_SHA256, pid=os.getpid())
    beat.update(updated_at=time.time(), profile=os.environ.get("HERMES_PROFILE") or "default")
    beat.update(fields)
    try:
        target = status_path()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(beat), encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        log.debug("could not write the heartbeat: %s", exc)


# Small hand-off files from the apps, one folder per kind:
#   origins/<session>.json  {device_id, platform, at}  which device last sent a prompt in that chat
#   goals/<session>.json    {goal, at}                 a line about what a busy chat is working toward
#   answers/<request>.json  {device_id, at}            the device that answered an approval

_last_cleanup = 0.0


def _read_marker(folder, key):
    """(body, age in seconds) for a marker file; (None, 0.0) when it is missing or unreadable."""
    if not key:
        return None, 0.0
    body = _json_or_none(push_dir() / folder / (re.sub(r"[^A-Za-z0-9._-]", "_", key) + ".json"))
    if not isinstance(body, dict):
        return None, 0.0
    return body, time.time() - float(body.get("at") or 0)


def session_origin(session_id):
    body, age = _read_marker("origins", session_id)
    return body if body is not None and age < MARKER_LIFETIME["origins"] else None


def session_goal(session_id, since=0.0):
    """What the chat is after, when the note was written during the activity that is on screen."""
    body, age = _read_marker("goals", session_id)
    text = (body or {}).get("goal")
    if not (isinstance(text, str) and text.strip()):
        return None
    written_at = time.time() - age
    fresh = written_at >= since - 5 and age <= LA_MAX_AGE        # clocks of phone and host differ a bit
    return text.strip()[:160] if fresh else None


def approval_answered_by(*request_ids):
    for request_id in request_ids:
        body, age = _read_marker("answers", request_id)
        if body and body.get("device_id") and age < MARKER_LIFETIME["answers"]:
            return str(body["device_id"])
    return None


def prune_markers():
    """At most once an hour, delete markers nobody can still need."""
    global _last_cleanup
    if time.time() - _last_cleanup < HOUR:
        return
    _last_cleanup = time.time()
    for folder, lifetime in MARKER_LIFETIME.items():
        _clear_old_files(push_dir() / folder, lifetime)


# ──────────────────────────────── devices ───────────────────────────────────

_PLATFORMS = ("ios", "macos", "watchos")
_repeat_files_logged: set[str] = set()


def load_devices(_gateway_url=""):
    """One record per (platform, APNs token). When a reinstall left two files with the same token the
    most recently registered one wins."""
    candidates = []
    for name in glob.glob(str(devices_dir() / "*.json")):
        record = _json_or_none(Path(name))
        if not isinstance(record, dict) or not record.get("apns_token") or record.get("platform") not in _PLATFORMS:
            continue
        candidates.append((str(record.get("registered_at") or ""), os.path.getmtime(name), name, record))
    chosen: dict[tuple, dict] = {}
    for _, _, name, record in sorted(candidates, key=lambda c: (c[0], c[1]), reverse=True):
        slot = (record["platform"], record["apns_token"])
        if slot in chosen:
            if name not in _repeat_files_logged:
                _repeat_files_logged.add(name)
                log.info("%s repeats a token that a newer device file has, so it is ignored", Path(name).name)
            continue
        chosen[slot] = record
    return list(chosen.values())


def activities_of(device):
    """The Live Activities a phone has open. Older app builds filed only the newest one, in flat fields."""
    entries = device.get("live_activities")
    if isinstance(entries, list):
        return [item for item in entries if isinstance(item, dict)]
    token = device.get("live_activity_token")
    if not token:
        return []
    return [{"session_id": device.get("live_activity_session_id"), "token": token,
             "started_at": device.get("live_activity_started_at")}]


def device_label(device):
    return device.get("device_name") or device.get("device_id") or "?"


def pending_request_ids(answer):
    """Ids named in an approval.pending answer. None means the answer was no list, as with an old gateway
    that returns just one approval, which tells us nothing about any others."""
    if not isinstance(answer, dict):
        return None
    for key in ("approvals", "pending"):
        rows = answer.get(key)
        if isinstance(rows, list):
            break
    else:
        return None
    ids = set()
    for row in filter(lambda r: isinstance(r, dict), rows):
        ids |= {str(row[k]) for k in ("request_id", "id") if row.get(k)}
    return ids


# ─────────────────────────────── small helpers ──────────────────────────────


def as_int(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


_CARD_NUMBERS = {"outputTokens": "output", "contextPercent": "context_percent",
                 "contextUsed": "context_used", "contextMax": "context_max"}


def usage_fields(usage, *, keep_empty=False):
    """Numbers for a Live Activity card out of a gateway usage block (snake or camel case)."""
    if not isinstance(usage, dict):
        return {}
    found = {card: as_int(usage.get(wire, usage.get(card))) for card, wire in _CARD_NUMBERS.items()}
    found["outputTokens"] = found["outputTokens"] or 0
    return found if keep_empty else {card: n for card, n in found.items() if n is not None}


def usage_block(fields):
    """The reverse of usage_fields: the gateway's spelling of numbers we kept for a card."""
    return {wire: fields.get(card) for card, wire in _CARD_NUMBERS.items()}


def describe_error(exc):
    """A short sentence about a failure that a person can read in the app."""
    inner = getattr(exc, "reason", None)
    text = str(exc if inner is None else inner)
    lowered = text.lower()
    if any(mark in text for mark in ("Errno 111", "Errno 61")) or "refused" in lowered:
        return "connection refused (no service is listening at that address)"
    if isinstance(exc, asyncio.TimeoutError) or "timed out" in lowered:
        return "timed out"
    reply = getattr(exc, "response", None)
    if getattr(reply, "status_code", None):
        return "WebSocket rejected with HTTP %s" % reply.status_code
    return text.strip("<>")[:160]


def message_text(row):
    body = row.get("text") or row.get("content")
    if isinstance(body, list):
        body = " ".join(str(piece.get("text") or "") for piece in body if isinstance(piece, dict))
    return body.strip() if isinstance(body, str) else ""


def packed(content):
    """The bytes that get sealed. Sizes are measured on these too, so the two always agree."""
    return json.dumps(content, separators=(",", ":"), ensure_ascii=False).encode()


def trim_for_apple(hermes, limit=2300):
    """Apple caps a payload at 4 KB and the encrypted part is ours. Shed thread lines, then shorten text."""
    def size():
        return len(packed(hermes))

    while size() > limit:
        thread = hermes.get("thread")
        text = hermes.get("text") or ""
        if thread:
            rest = thread[1:]
            if rest:
                hermes["thread"] = rest
            else:
                del hermes["thread"]
        elif len(text) > 400:
            hermes["text"] = text[:max(400, len(text) - 300)]
        else:
            break


class ConfigChanged(Exception):
    """The app rewrote the settings: reconnect using them."""


class ReleaseIdle(Exception):
    """Quiet for a long time: hang up so the gateway can let its sessions rest."""


class CodeChanged(Exception):
    """This file changed on disk; whoever runs it reloads or restarts it."""


# ───────────────────────────────── plain HTTP ───────────────────────────────


class HttpFailure(Exception):
    """The server replied, but not with a success status."""

    def __init__(self, status, reason, body):
        super().__init__(f"HTTP {status} {reason}")
        self.status, self.reason, self.body = status, reason, body


def fetch(url, *, method="GET", body=None, headers=None,
          timeout=20):
    """(status, text). A non-2xx status raises HttpFailure; network trouble raises what urllib raises."""
    req = urllib.request.Request(url, method=method, headers=dict(headers or {}))
    wire_body = None if body is None else json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data=wire_body, timeout=timeout) as answer:
            return answer.status, answer.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        raise HttpFailure(err.code, err.reason, err.read().decode("utf-8", "replace")) from None


# ───────────────────────────────── delivery ─────────────────────────────────

LA_PLAIN_WORDS = {"waiting": "Waiting for you", "done": "Turn finished", "error": "The turn failed", **PHASE_WORDS}
CATEGORY_BY_KIND = {"approval": "HERMES_APPROVAL", "clarify": "HERMES_CLARIFY", "error": "HERMES_ERROR",
                    "settled": "HERMES_INFO"}


APPLE_LIMIT = 4096             # bytes Apple takes in one alert payload
SEAL_OVERHEAD = 12 + 16        # the nonce in front and the tag behind


def fit_for_sealing(content, room):
    """A copy of `content` short enough that, sealed and in base64, it takes at most `room` bytes.
    Thread lines go first, then the reply text is shortened, then the body."""
    most = room // 4 * 3 - SEAL_OVERHEAD
    fitted = dict(content)
    hermes = fitted["hermes"] = dict(fitted.get("hermes") or {})
    while len(packed(fitted)) > most:
        thread, text, body = hermes.get("thread"), hermes.get("text") or "", fitted.get("body") or ""
        if thread:
            hermes["thread"] = thread[1:]
            if not hermes["thread"]:
                del hermes["thread"]
        elif len(text) > 80:
            hermes["text"] = text[:len(text) - max(40, len(text) // 4)]
        elif len(body) > 80:
            fitted["body"] = body[:len(body) - max(40, len(body) // 4)]
        else:
            break
    return fitted


def seal_for_device(device, content, room=APPLE_LIMIT - 512):
    """Encrypt with the AES-256-GCM key this install made, shortened first to fit in `room`. The relay
    forwards the bytes unread and the app's notification extension decrypts them."""
    if not device.get("payload_key"):
        return None
    nonce = os.urandom(12)
    plain = packed(fit_for_sealing(content, room))
    cipher = AESGCM(base64.b64decode(device["payload_key"])).encrypt(nonce, plain, None)
    return base64.b64encode(nonce + cipher).decode()


def device_routing(device, payload):
    """The payload's routing block, naming the connection the device uses for this gateway, so the
    app reads that gateway's Private list and opens the chat there."""
    hermes = dict(payload.get("hermes", {}))
    if device.get("connection_id"):
        hermes["connection_id"] = str(device["connection_id"])
    return hermes


def alert_fields(payload, device=None):
    """What the app opens: the alert words, the category and the routing block. Only ever sent sealed."""
    aps = payload.get("aps", {})
    inner = dict(aps.get("alert") or {})
    inner.update(category=aps.get("category", "HERMES_TURN"), thread_id=aps.get("thread-id", ""),
                 interruption=aps.get("interruption-level", "active"), hermes=device_routing(device or {}, payload))
    return inner


# What a lock screen shows if the app's extension can't, or won't, open the real words.
GENERIC_ALERT = {"title": "Nollie", "body": "New message"}
# The only routing a direct push carries in the clear: opaque ids and the kind, never words from the chat.
OPEN_ROUTING = ("kind", "session_id", "profile", "gateway", "request_id", "connection_id")

_APPLE_FIXED_HEADERS = {"apns-priority": "10", "apns-expiration": "0", "content-type": "application/json"}


def _apple_host(device, forced_sandbox):
    development = forced_sandbox or device.get("apns_environment") == "development"
    return ("api.sandbox.push.apple.com" if development else "api.push.apple.com")


def curl_config(url, headers, body):
    """A curl config file (read with -K -) for one request, so no secret has to sit on the command line."""
    def quoted(text):
        escapes = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t", "\v": "\\v"}
        return '"' + "".join(escapes.get(char, char) for char in text) + '"'
    lines = [f"url = {quoted(url)}"]
    lines += [f"header = {quoted(f'{name}: {value}')}" for name, value in headers]
    lines.append(f"data-binary = {quoted(body)}")
    return "\n".join(lines) + "\n"


class APNs:
    """Sends one payload to one device: through the Nollie relay if the device signed up with it,
    otherwise directly to Apple using the key from the settings."""

    dry_run = False

    def __init__(self):
        key_file, self.key_id, self.team_id = (env("HERMES_PUSH_APNS_" + part) for part in ("KEY_FILE", "KEY_ID", "TEAM_ID"))
        self.direct = "" not in (key_file, self.key_id, self.team_id)
        self._pem = Path(key_file).read_text(encoding="utf-8") if self.direct else ""
        self.topic = env("HERMES_PUSH_APNS_TOPIC", "com.coreykozarski.nollie")
        self.force_sandbox = flag("HERMES_PUSH_APNS_SANDBOX")
        self._jwt = ("", 0.0)
        self.last_response = ""      # what the far side said most recently; the app's test shows it
        if not self.direct:
            log.info("no APNs key on this machine, so pushes go through the Nollie relay")

    def send(self, device, payload, *, push_type="alert", collapse_id=None, token_override=None):
        if device.get("relay"):
            return self._via_relay(device, push_type, payload, collapse_id, token_override)
        if push_type == "alert":
            payload = self._direct_alert(device, payload)
        return self._to_apple(device, push_type, payload, collapse_id, token_override)

    # relay

    @staticmethod
    def _live_activity_request(aps, token):
        # A Live Activity push cannot be decrypted by anyone, so only stock words go through it.
        state = dict(aps.get("content-state") or {})
        state["detail"] = LA_PLAIN_WORDS.get(state.get("phase"), "Working…")
        request = {"push_type": "liveactivity", "token": token, "content_state": state,
                   "event": aps.get("event") or "update"}
        renames = {"attributes": "attributes", "alert": "alert", "dismissal-date": "dismissal_date"}
        request.update({new: aps[old] for old, new in renames.items() if aps.get(old)})
        return request

    def _relay_request(self, device, kind, payload, collapse_id, token):
        aps = payload.get("aps", {})
        thread = aps.get("thread-id", "")
        if kind == "liveactivity":
            return self._live_activity_request(aps, token)
        if kind == "sound":
            return {"push_type": "sound", "thread_id": thread, "collapse_id": collapse_id}
        if kind != "alert":
            return {"push_type": kind}
        inner = alert_fields(payload, device)
        sealed = seal_for_device(device, inner)
        if sealed is None:
            log.warning("device %s uses a relay but has no payload_key: skipped", device.get("device_id"))
            return None
        return {"push_type": "alert", "enc": sealed, "collapse_id": collapse_id, "thread_id": thread,
                "interruption": inner["interruption"]}

    def _via_relay(self, device, kind, payload, collapse_id, token):
        link = device.get("relay") or {}
        if not all(link.get(part) for part in ("url", "install_id", "secret")):
            return False
        request = self._relay_request(device, kind, payload, collapse_id, token)
        if request is None:
            return False
        request["install_id"], request["secret"] = link["install_id"], link["secret"]
        if self.dry_run:
            log.info("dry run: relay %s for %s", kind, device_label(device))
            return True
        endpoint = str(link["url"]).rstrip("/") + "/v1/push"
        try:
            status, text = fetch(endpoint, method="POST", body=request,
                                 headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
        except HttpFailure as refused:
            self.last_response = f"relay {refused.status}: {refused.body[:200]}"
            log.warning("relay answered %s for %s: %s", refused.status, device.get("device_id"), refused.body[:200])
            return False
        except Exception as exc:  # noqa: BLE001
            self.last_response = f"relay unreachable: {exc}"
            log.warning("could not reach the relay: %s", exc)
            return False
        self.last_response = f"relay {status}: {text[:160]}"
        return status == 200

    # straight to Apple

    @staticmethod
    def _direct_alert(device, payload):
        """A direct alert reads the same on the lock screen as a relayed one: generic words and
        mutable-content, with the real ones sealed for the app's extension, which checks Hide details,
        App Lock and Private bots before it opens them. With no key to seal with, nothing real goes.
        Every device file carries a key; the fallback is for files written by older apps."""
        aps, hermes = payload.get("aps", {}), device_routing(device, payload)
        if not aps.get("alert") or hermes.get("kind") == "test":
            return payload          # the test words are fixed and hold nothing from a chat
        # The category stays in the clear, so Approve, Deny and Reply still show if the extension runs out of time.
        outer = {"alert": dict(GENERIC_ALERT), "mutable-content": 1, "category": aps.get("category", "HERMES_TURN"),
                 "thread-id": aps.get("thread-id", ""), "interruption-level": aps.get("interruption-level", "active")}
        if aps.get("sound"):
            outer["sound"] = aps["sound"]
        direct = {"aps": outer, "hermes": {name: hermes[name] for name in OPEN_ROUTING if hermes.get(name)}}
        room = APPLE_LIMIT - len(json.dumps({**direct, "enc": ""}).encode())
        try:
            sealed = seal_for_device(device, alert_fields(payload, device), room)
        except Exception as exc:  # noqa: BLE001
            log.warning("could not seal an alert for %s (%s): sending the generic words only",
                        device.get("device_id"), type(exc).__name__)
            sealed = None
        if sealed and len(sealed) <= room:
            direct["enc"] = sealed
        elif sealed:
            log.warning("an alert for %s would not fit even shortened: sending the generic words only",
                        device.get("device_id"))
        return direct

    def _provider_token(self):
        value, made = self._jwt
        if time.time() - made > 45 * 60:
            claims = {"iss": self.team_id, "iat": int(time.time())}
            value = jwt.encode(claims, self._pem, algorithm="ES256", headers={"kid": self.key_id})
            self._jwt = (value, time.time())
        return value

    def _topic_for(self, device, kind):
        # Phone, Mac and watch builds each have their own bundle id, and the device file says which.
        base = device.get("bundle_id") or self.topic
        if kind == "liveactivity":
            return base + ".push-type.liveactivity"
        if kind == "complication" and device.get("platform") == "watchos":
            return base + ".complication"
        return base

    def _apple_headers(self, topic, kind, collapse_id):
        headers = dict(_APPLE_FIXED_HEADERS)
        headers["apns-push-type"] = "alert" if kind == "sound" else kind
        headers["authorization"] = "bearer " + self._provider_token()
        headers["apns-topic"] = topic
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        return list(headers.items())

    def _to_apple(self, device, kind, payload, collapse_id, token):
        token = token or device.get("apns_token")
        if not token or not self.direct:
            return False
        topic = self._topic_for(device, kind)
        host = _apple_host(device, self.force_sandbox)
        if self.dry_run:
            log.info("dry run, would send %s to %s through %s with topic %s", kind, device_label(device), host, topic)
            return True
        # The headers carry the provider token, so curl reads them from stdin with the body. Neither the
        # token nor the device token ever shows up in the process list.
        url = f"https://{host}/3/device/{urllib.parse.quote(str(token), safe='')}"
        config = curl_config(url, self._apple_headers(topic, kind, collapse_id), json.dumps(payload))
        command = ["curl", "-sS", "--http2", "-o", "-", "-w", "\n%{http_code}", "-K", "-"]
        try:
            done = subprocess.run(command, input=config, capture_output=True, text=True, timeout=30)
        except Exception as exc:  # noqa: BLE001
            # Never log the exception itself: a timeout carries the whole command.
            reason = "timed out" if isinstance(exc, subprocess.TimeoutExpired) else "could not be run"
            log.warning("curl for APNs %s", reason)
            return False
        # curl prints the body, then a newline and the status code (see -w above).
        body, _, code = (done.stdout or "").rpartition("\n")
        accepted = code == "200"
        if not accepted:
            log.warning("APNs refused %s (%s): %s", device.get("device_id"), code, body.strip()[:300])
        return accepted


# ─────────────────────────────────── gateway ────────────────────────────────


class Gateway:
    """One websocket to the gateway (a JSON message per line) and a few plain REST reads."""

    def __init__(self):
        address = env("HERMES_PUSH_GATEWAY_URL").rstrip("/")
        if address == "":
            sys.exit("set HERMES_PUSH_GATEWAY_URL")
        self.url, self.transport = address, ""
        self.public_url = env("HERMES_PUSH_PUBLIC_URL").rstrip("/") or address
        self.token, self.bearer, self.refresh_token = (
            env("HERMES_PUSH_GATEWAY_" + part) for part in ("TOKEN", "BEARER", "REFRESH_TOKEN"))
        self.headers = {}
        self.headers.update(self._identity_headers())
        self.ws = None
        self._counter = 0
        self._pending = {}
        self.events = asyncio.Queue()

    def _identity_headers(self):
        """Sent on every call. Some edge networks reject Python's stock agent, so introduce ourselves."""
        found = {"User-Agent": USER_AGENT}
        service_id, service_secret = env("HERMES_PUSH_CF_ACCESS_CLIENT_ID"), env("HERMES_PUSH_CF_ACCESS_CLIENT_SECRET")
        if service_id and service_secret:
            found.update({"CF-Access-Client-Id": service_id, "CF-Access-Client-Secret": service_secret})
        if self.bearer:
            found["Authorization"] = "Bearer " + self.bearer
        elif self.token:
            found["X-Hermes-Session-Token"] = self.token
        return found

    def _http(self, method, path, body=None, *, _again=True):
        wanted = {**self.headers, "Accept": "application/json", "Content-Type": "application/json"}
        try:
            reply = fetch(self.url + path, method=method, body=body, headers=wanted)[1]
        except HttpFailure as refused:
            expired = refused.status == 401 and _again and self.refresh_token
            if not (expired and self.refresh()):
                raise
            return self._http(method, path, body, _again=False)
        return json.loads(reply)

    def refresh(self):
        """Trade the refresh token for a fresh bearer and write both to the settings file."""
        anonymous = {name: value for name, value in self.headers.items() if name != "Authorization"}
        anonymous["Content-Type"] = "application/json"
        try:
            grant = json.loads(fetch(self.url + "/auth/native/refresh", method="POST",
                                     body={"refresh_token": self.refresh_token}, headers=anonymous)[1])
        except Exception as exc:  # noqa: BLE001
            log.warning("could not renew the sign-in: %s", exc)
            return False
        if not grant.get("access_token"):
            return False
        self.bearer = grant["access_token"]
        self.headers["Authorization"] = "Bearer " + self.bearer
        if grant.get("refresh_token"):
            self.refresh_token = grant["refresh_token"]
            save_conf_value("HERMES_PUSH_GATEWAY_REFRESH_TOKEN", self.refresh_token)
        save_conf_value("HERMES_PUSH_GATEWAY_BEARER", self.bearer)
        log.info("gateway sign-in renewed")
        return True

    @staticmethod
    def _ticket_error(refused):
        hint = " (sign-in rejected: sign in for the companion again)" if refused.status in (401, 403) else ""
        if any(word in refused.body[:300].lower() for word in ("cloudflare", "cf-")):
            hint = " (Cloudflare refused it: the companion needs the Access service token, or use a loopback URL)"
        return RuntimeError(str(refused) + hint)

    def _socket_address(self):
        """Websocket URL carrying its credential, plus a word for how we signed in."""
        scheme, _, host = self.url.partition("://")
        base = f"{'wss' if scheme == 'https' else 'ws'}://{host}/api/ws"
        if not self.bearer:
            return base + "?token=" + self.token, "session token"
        try:
            ticket = self._http("POST", "/api/auth/ws-ticket", {})["ticket"]
        except HttpFailure as refused:
            raise self._ticket_error(refused) from None
        except urllib.error.URLError as exc:
            raise RuntimeError(describe_error(exc)) from None
        return base + "?ticket=" + ticket, "companion bearer"

    async def connect(self):
        try:
            address, how = await asyncio.to_thread(self._socket_address)
            hidden = ("Authorization", "X-Hermes-Session-Token")
            extras = {name: value for name, value in self.headers.items() if name not in hidden}
            # A stuck upgrade behind a tunnel must not stall the heartbeat.
            opening = websockets.connect(address, additional_headers=extras, max_size=64 << 20)
            self.ws = await asyncio.wait_for(opening, timeout=30)
        except Exception as exc:  # noqa: BLE001
            raise ConnectionError(self.url + ": " + describe_error(exc)) from None
        self.transport = self.url + " (" + how + ")"
        self._reader = asyncio.create_task(self._read_loop())
        # Tell the gateway it may route server requests to us. We never reply to them (the phone does), yet
        # without this note the gateway cancels any approval raised while we are the only client attached.
        await self.call("client.capabilities", {"server_requests": True})

    async def _read_loop(self):
        try:
            async for chunk in self.ws:
                for text in str(chunk).splitlines():
                    parsed = _parse_line(text)
                    if parsed is not None:
                        await self._dispatch(parsed)
        except Exception as exc:  # noqa: BLE001
            log.warning("reading from the socket stopped: %s", exc)
        finally:
            await self.events.put({"type": "__closed__"})

    async def _dispatch(self, message):
        number, method = message.get("id"), message.get("method")
        if method == "event":
            await self.events.put(message.get("params") or {})
        elif isinstance(number, int):
            self._settle_call(number, message)
        elif isinstance(number, str) and method:
            # Meant for the phone (an approval or a question). Answering here would settle it first and
            # pull the phone's card, so it only becomes news for the relay loop.
            await self.events.put({"type": "__request__", "id": number, "method": method,
                                   "params": message.get("params") or {}})

    def _settle_call(self, number, message):
        waiter = self._pending.pop(number, None)
        if waiter is None:
            return
        failure = message.get("error")
        if failure is not None:
            waiter.set_exception(RuntimeError(failure.get("message", "rpc error")))
        else:
            waiter.set_result(message.get("result") or {})

    async def call(self, method, params=None, timeout=60):
        self._counter += 1
        number = self._counter
        self._pending[number] = waiter = asyncio.get_running_loop().create_future()
        frame = {"jsonrpc": "2.0", "id": number, "method": method, "params": params or {}}
        await self.ws.send(json.dumps(frame))
        try:
            return await asyncio.wait_for(waiter, timeout)
        finally:
            self._pending.pop(number, None)


def _parse_line(text):
    """One JSON message from a line of the socket, or None for blank or broken lines."""
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


# ───────────────────────────────── the relay ────────────────────────────────

REQUEST_PROMPTS = {"sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"}
PHASE_OF_EVENT = {"message.start": "thinking", "reasoning.delta": "thinking", "thinking.delta": "thinking",
                  "message.delta": "streaming", "tool.start": "tool", "tool.generating": "tool",
                  "tool.complete": "thinking"}
PROGRESS_EVENTS = frozenset(PHASE_OF_EVENT) | {"session.usage", "message.complete"}
CARRIED_MESSAGE_KEYS = ("display_kind", "display_metadata", "error", "status", "finish_reason", "tool_calls")


def live_card(started, **fields):
    """The state a Live Activity card shows, with defaults for what a patch leaves out."""
    card = {"phase": "streaming", "detail": "Working…", "outputTokens": 0, "contextPercent": None,
            "needsAttention": False, "startedAtUnix": float(started), "endedAtUnix": None}
    card.update(fields)
    return card


def _forget_old(table, keep_seconds, now):
    return {key: stamp for key, stamp in table.items() if now - stamp < keep_seconds}


class Relay:
    REAP_GRACE = 45.0

    def __init__(self):
        self.courier, self.gw = APNs(), Gateway()
        self.poll = float(env("HERMES_PUSH_POLL_SECONDS") or 3)
        self.release_after = float(env("HERMES_PUSH_RELEASE_IDLE_SECONDS") or 600)
        # Everything below starts empty. Keys are runtime session ids unless a comment says otherwise.
        self.__dict__.update(
            attached={}, # one entry per followed chat; fields: title, bot, profile, status, source and the stored id
            labels={},               # profile -> name shown to people
            bot_chats={},            # profile -> its Bot Chat, as profiles.list reports it
            session_profile={},      # stored id -> profile
            _touched=set(), _live_running=set(), _live_ok=False,
            notified=set(), open_approvals={}, _approval_gone_since={},
            la_phase={}, la_usage={}, _usage_pushed={},
            _la_started_for={}, # stored id -> time of the last push-to-start
            _la_reaped={}, _la_idle_since={},   # both keyed by activity token
            _finish_pushed={}, _turn_pushed_at={}, _bot_chat_pushed={},
            last_test={}, last_la={},
        )
        self._profiles_read = self._bot_chat_check_at = self._complication_at = 0.0
        self._last_running_at = time.time()
        self._conf_seen = conf_mtime()

    # heartbeat

    def _beat(self, **fields):
        write_status(**fields, **self.last_test, **self.last_la)

    def _beat_up(self):
        self._beat(connected=True, gateway=self.gw.public_url, transport=self.gw.transport,
                   attached=len(self.attached), devices=len(load_devices()))

    def _beat_down(self, error):
        self._beat(connected=False, gateway=self.gw.public_url, transport=self.gw.transport, error=error)

    def _remember_la(self, what, ok, detail=None):
        said = self.courier.last_response if detail is None else detail
        self.last_la = {"last_la_event": what, "last_la_ok": ok, "last_la_response": said[:300],
                        "last_la_at": time.time()}

    @staticmethod
    def _activity_notes(device):
        """One short line per open activity of a phone, or a line saying there is none."""
        who = device_label(device)[:14]
        entries = activities_of(device)
        if not entries:
            return [f"{who}: no activity"]
        now = time.time()
        return [f"{who}: session={(item.get('session_id') or '-')[:12]} age={int(now - float(item.get('started_at') or 0))}s"
                for item in entries]

    def _why_no_activity(self, what, stored):
        """No phone qualified: write down what each phone's file holds, so a missing token is visible."""
        phones = [d for d in load_devices() if d.get("platform") == "ios"]
        notes = [line for phone in phones for line in self._activity_notes(phone)]
        self._remember_la(f"no card for {what}, session {stored[:12]}", False, "; ".join(notes) or "no iOS device files")

    # notifications

    def _recipients(self, kind, meta, *, skip, only):
        wants_sound = kind != "settled"
        origin = session_origin(str(meta.get("session_id", ""))) or {}
        started_on_mac = origin.get("platform") == "macos"
        chosen = []
        for device in load_devices():
            who = device.get("device_id")
            if device.get("platform") == "watchos" or who in skip:
                continue                         # a phone's alert is mirrored to its watch anyway
            if only is not None and who not in only:
                continue
            hushed = device.get("platform") == "ios" and device.get("mute_desktop_origin")
            if wants_sound and started_on_mac and hushed:
                log.info("not sending %s to %s: started on a Mac and this phone wants quiet", kind, device_label(device))
                continue
            chosen.append(device)
        return chosen

    def push_all(self, kind, title, body, meta, collapse=None, skip=frozenset(), only=None, reached=None):
        """Notify every eligible device and report how many took it.
        `skip` names devices that are already aware, `only` limits who is considered, and `reached`
        gathers the ids that accepted. Kind "settled" is silent: it swaps out an older banner and
        asks the person for nothing."""
        hermes = {"kind": kind, "gateway": self.gw.public_url, **meta}
        trim_for_apple(hermes)
        urgency = {"settled": "passive", "approval": "time-sensitive", "clarify": "time-sensitive"}
        aps = {"alert": {"title": title, "body": body}}
        aps["thread-id"] = meta.get("session_id", "")
        aps["category"] = CATEGORY_BY_KIND.get(kind, "HERMES_TURN")
        aps["interruption-level"] = urgency.get(kind, "active")
        if kind != "settled":
            aps["sound"] = "default"
        prune_markers()
        took_it = self._deliver_to(self._recipients(kind, meta, skip=skip, only=only), {"aps": aps, "hermes": hermes},
                                   f"{kind} ({title[:60]})", collapse)
        self.nudge_watches()
        if reached is not None:
            reached |= set(took_it)
        return len(took_it)

    def _deliver_to(self, devices, envelope, what, collapse=None):
        """Send one envelope to each device; the ids of those that accepted it."""
        accepted = []
        for device in devices:
            if self.courier.send(device, envelope, collapse_id=collapse):
                accepted.append(device.get("device_id"))
                log.info("%s delivered to %s", what, device_label(device))
            else:
                log.info("%s FAILED for %s", what, device_label(device))
        return accepted

    def nudge_watches(self):
        """Ask watch complications to reload. Apple rations them, so at most one round per three minutes."""
        if time.time() < self._complication_at + 180:
            return
        watches = [d for d in load_devices() if d.get("platform") == "watchos"]
        if watches:
            self._complication_at = time.time()
            ping = {"aps": {"content-available": 1}, "hermes": {"kind": "complication", "gateway": self.gw.public_url}}
            for watch in watches:
                self.courier.send(watch, ping, push_type="complication")

    def answer_test_request(self):
        """The app leaves test-request.json; reply with a real push and record the nonce, so the app can
        tell a push that was sent from one that arrived."""
        request_file = status_path().with_name("test-request.json")
        if not request_file.exists():
            return
        asked = _json_or_none(request_file)
        request_file.unlink(missing_ok=True)
        nonce = str((asked.get("nonce") if isinstance(asked, dict) else None) or uuid.uuid4())
        count = self.push_all("test", "Nollie", "Your gateway can reach this device ✓",
                              dict(nonce=nonce, session_id=""), collapse="nollie-test")
        self.last_test = dict(last_test_nonce=nonce, last_test_devices=count, last_test_at=time.time(),
                              last_test_detail=self.courier.last_response)
        self._beat_up()
        log.info("test notification %s reached %d device(s)", nonce[:8], count)

    def meta(self, sid):
        entry = self.attached.get(sid, {})
        return {"session_id": entry.get("stored", sid), "profile": entry.get("profile", "default")}

    # Live Activities

    def live_activity_devices(self, stored, runtime_id=""):
        """One copy of the device record for each open activity of this session, each carrying its own
        token. The phone files an activity under the stored id, but the gateway sometimes names only the
        runtime id, so either matches."""
        wanted = {stored, runtime_id} - {""}
        cutoff = time.time() - LA_MAX_AGE
        copies = []
        for device in load_devices():
            if device.get("platform") != "ios":
                continue
            for entry in activities_of(device):
                owner = entry.get("session_id")
                young = float(entry.get("started_at") or 0) > cutoff
                if entry.get("token") and young and (owner in wanted or not owner):
                    copies.append(dict(device, live_activity_token=entry["token"], live_activity_session_id=owner,
                                       live_activity_started_at=entry.get("started_at")))
        return copies

    def _push_card(self, device, label, aps, token=None):
        token = token or device["live_activity_token"]
        sent = self.courier.send(device, {"aps": aps}, push_type="liveactivity", token_override=token)
        self._remember_la(label, sent)
        return sent

    def update_live_activities(self, stored, patch, alert=None, runtime_id=""):
        """Update the card during a turn. Passing `alert` makes the Island expand and buzz. Returns who got it."""
        targets = self.live_activity_devices(stored, runtime_id)
        if not targets and patch.get("phase") in PHASE_WORDS:
            self.start_live_activities(stored, runtime_id, patch)         # app closed: begin one by push
            targets = self.live_activity_devices(stored, runtime_id)
        if alert and not targets:
            self._why_no_activity("alert update", stored)
        stamp = int(time.time())
        reached = set()
        for device in targets:
            began = device.get("live_activity_started_at") or 0
            card = live_card(began or stamp, **patch)
            if "goal" not in card:
                card["goal"] = session_goal(device.get("live_activity_session_id") or stored, float(began))
                if not card["goal"]:
                    del card["goal"]
            aps = {"timestamp": stamp, "event": "update", "content-state": card}
            if alert:
                aps["alert"] = dict(alert, sound="default")
            label = "update alert" if alert else "update"
            reached |= {device.get("device_id")} if self._push_card(device, label, aps) else set()
        return reached

    def start_live_activities(self, stored, runtime_id, patch=None):
        """Start an activity remotely on phones with a push-to-start token, at most once per turn."""
        if self._la_started_for.get(stored, 0) + 600 > time.time():
            return 0
        patch = patch or {}
        session = self.attached.get(runtime_id, {"stored": stored})
        profile = session.get("profile") or "default"
        stamp = int(time.time())
        card = {**live_card(stamp, phase="thinking", detail="Thinking…"), **patch}
        begun = 0
        for device in load_devices():
            start_token = device.get("live_activity_push_to_start_token")
            if device.get("platform") != "ios" or not start_token:
                continue
            if any(e.get("token") and e.get("session_id") in (stored, runtime_id) for e in activities_of(device)):
                continue
            look = (device.get("bots") or {}).get(profile) or {}
            attributes = {"sessionTitle": session.get("title") or "Hermes", "storedSessionID": stored,
                          "connectionID": device.get("connection_id") or "", "profile": profile, "model": "",
                          "tintHex": look.get("hex") or "", "avatar": look.get("avatar") or "",
                          "botName": look.get("label") or session.get("bot") or profile}
            aps = {"timestamp": stamp, "event": "start", "content-state": card,
                   "attributes-type": "HermesTurnAttributes", "attributes": attributes}
            begun += self._push_card(device, "start", aps, token=start_token)
        if not begun:
            return begun
        self._la_started_for[stored] = time.time()
        log.info("push-started %d Live Activities for %s", begun, stored[:12])
        return begun

    def end_live_activities(self, stored, phase, bot="Hermes", runtime_id="", usage=None):
        """Ends a turn's card in two stages. First an update marks it Finished or Failed while the
        Island still shows it; afterwards an end push lets it remain on the Lock Screen for a while.
        The reply arrives on its own as a regular notification."""
        targets = self.live_activity_devices(stored, runtime_id)
        if not targets:
            self._why_no_activity(f"finish {phase}", stored)
        island = seconds_setting("HERMES_PUSH_FINISH_ISLAND", 30)
        linger = seconds_setting("HERMES_PUSH_FINISH_LINGER", 60)
        stamp = int(time.time())
        words = ("The turn failed", "The turn failed. Tap to see why.") if phase != "done" else (
            "Turn finished", "Finished. Tap to read the reply.")
        reached = set()
        for device in targets:
            card = live_card(device.get("live_activity_started_at") or stamp, phase=phase, detail=words[0],
                             endedAtUnix=float(stamp), **usage_fields(usage, keep_empty=True))
            aps = {"timestamp": stamp, "event": "update", "content-state": card}
            if flag("HERMES_PUSH_FINISH_EXPAND"):
                aps["alert"] = {"title": bot, "body": words[1], "sound": "default"}
            if self._push_card(device, f"finish update ({phase})", aps):
                reached.add(device.get("device_id"))
                self._end_after(device, card, island, linger)
        return reached

    def _end_after(self, device, card, delay, linger):
        def end_now():
            stamp = int(time.time())
            self._push_card(device, f"finish end (after {delay}s, stays {linger}s)",
                            {"timestamp": stamp, "event": "end", "content-state": card, "dismissal-date": stamp + linger})
        try:
            asyncio.get_event_loop().call_later(delay, end_now)
        except RuntimeError:
            end_now()

    def _continued_elsewhere(self, stored):
        """When a long turn compacts its context it carries on under a fresh stored id. Is that one busy?"""
        profile = self.session_profile.get(stored)
        query = "?" + urllib.parse.urlencode({"profile": profile}) if profile else ""
        route = f"/api/sessions/{urllib.parse.quote(stored, safe='')}/latest-descendant{query}"
        try:
            heir = self.gw._http("GET", route).get("session_id")
        except Exception:  # noqa: BLE001
            return False
        return bool(heir) and heir != stored and heir in self._live_running

    def _busy_ids(self):
        ids = set(self._live_running)
        for sid, entry in self.attached.items():
            if _is_busy(entry.get("status")):
                ids.update([sid, entry.get("stored") or sid])
        return ids

    def _reap_verdict(self, token, stored, began, now, busy):
        """What to do with one open activity: keep, wait, forget or end."""
        recent = now - began < 120 or now - self._la_started_for.get(stored, 0) < 120
        if stored in busy or recent:
            self._la_idle_since.pop(token, None)
            return "keep"
        if now - began > LA_MAX_AGE:
            return "dead"                       # iOS closed it on its own; the token is spent
        idle_since = self._la_idle_since.setdefault(token, now)
        if now - idle_since < self.REAP_GRACE:
            return "wait"
        if self._continued_elsewhere(stored):
            self._la_idle_since.pop(token, None)
            return "keep"
        return "end"

    def reap_live_activities(self):
        """End activities whose turn is over already (the phone filed its token after the finish went to
        nobody). It acts only on what it saw this poll: a live list was read and the session stayed idle
        for REAP_GRACE seconds."""
        if not self._live_ok:
            return 0
        now, busy = time.time(), self._busy_ids()
        pairs = []
        for device in load_devices():
            if device.get("platform") == "ios":
                pairs += [(device, e) for e in activities_of(device) if e.get("token") and e["token"] not in self._la_reaped]
        closed = 0
        for device, entry in pairs:
            token, stored = entry["token"], entry.get("session_id") or ""
            began = float(entry.get("started_at") or 0)
            if self._reap_verdict(token, stored, began, now, busy) == "end":
                done = live_card(began or now, phase="done", detail="Turn finished", endedAtUnix=float(now))
                self._push_card(device, "end (turn already over)",
                                {"timestamp": int(now), "event": "end", "content-state": done,
                                 "dismissal-date": int(now) + 60}, token=token)
                self._la_reaped[token] = now
                self._la_idle_since.pop(token, None)
                closed += 1
                log.info("closed an activity for %s; its turn was over", stored[:12])
        tokens_seen = {e["token"] for _, e in pairs}
        self._la_idle_since = {t: since for t, since in self._la_idle_since.items() if t in tokens_seen}
        if len(self._la_reaped) > 200:
            self._la_reaped = _forget_old(self._la_reaped, 86400, now)
        return closed

    def _show_phase(self, sid, entry, phase, **more):
        patch = {**self.la_usage.get(sid, {}), "phase": phase, "detail": PHASE_WORDS.get(phase, "Working…"), **more}
        self.update_live_activities(entry["stored"], patch, runtime_id=sid)

    def _current_phase(self, sid, fallback):
        return self.la_phase[sid][0] if self.la_phase.get(sid) else fallback

    def _on_phase(self, sid, entry, phase):
        """Reflect the turn's phase on the Live Activity, only when it changes."""
        if self._current_phase(sid, None) != phase:
            self.la_phase[sid] = (phase, time.time())
            self._show_phase(sid, entry, phase)

    def _on_usage(self, sid, entry, usage):
        numbers = usage_fields(usage)
        if not numbers:
            return
        self.la_usage[sid] = numbers
        if time.time() - self._usage_pushed.get(sid, 0) >= 3:
            self._usage_pushed[sid] = time.time()
            self._show_phase(sid, entry, self._current_phase(sid, "thinking"))

    def _back_to_work(self, sid, entry):
        self._show_phase(sid, entry, self._current_phase(sid, "streaming"), needsAttention=False)

    # finding sessions

    def _listed_sessions(self, profiles):
        """(row, profile to assume) pairs from the all-profiles list, or from each profile's own list."""
        try:
            everything = self.gw._http("GET", "/api/profiles/sessions?profile=all&order=recent&limit=200")
            return [(row, None) for row in everything.get("sessions") or []]
        except Exception as exc:  # noqa: BLE001
            log.debug("the all-profiles list failed (%s); trying each profile", exc)
        pairs = []
        for name in filter(None, profiles):
            query = urllib.parse.urlencode({"order": "recent", "limit": 60, "profile": name})
            try:
                answer = self.gw._http("GET", "/api/sessions?" + query)
            except Exception as exc:  # noqa: BLE001
                log.debug("no session list for %s: %s", name, exc)
                continue
            pairs.extend((row, name) for row in answer.get("sessions") or [])
        return pairs

    def _read_session_profiles(self, profiles, force=False):
        """Maps each stored session to the bot that owns it. Always rebuilt from scratch, never merged:
        a wrong profile name in session.resume would drag the chat into another profile's store."""
        if not force and time.time() < self._profiles_read + 60:
            return
        owners = {}
        for row, assumed in self._listed_sessions(profiles):
            if isinstance(row, dict) and row.get("id") and (row.get("profile") or assumed):
                owners[str(row["id"])] = str(row.get("profile") or assumed)
        for key in ("id", "resolved_id"):
            owners.update({str(chat[key]): name for name, chat in self.bot_chats.items() if chat.get(key)})
        self._profiles_read = time.time()
        if owners:
            self.session_profile = owners

    def _ask_each_profile(self, stored, profiles):
        """Fallback for an id that no listing contains: query every profile's store for the session."""
        for name in filter(None, profiles):
            route = f"/api/sessions/{urllib.parse.quote(stored)}?profile={urllib.parse.quote(name)}"
            try:
                answer = self.gw._http("GET", route)
            except Exception:  # noqa: BLE001
                continue
            known = isinstance(answer, dict) and any(answer.get(key) for key in ("id", "session"))
            if known:
                return name
        return None

    def _note_bot_chats(self, roster):
        for item in roster:
            chat = item.get("canonical_session")
            if item.get("name") and isinstance(chat, dict) and chat.get("id"):
                self.bot_chats[item["name"]] = dict(
                    id=chat["id"], resolved_id=chat.get("resolved_id") or chat["id"],
                    message_count=chat.get("message_count") or 0, last_active=chat.get("last_active") or 0)

    async def _ask(self, method, params, wait):
        """Call the gateway; give None instead of an exception when it fails."""
        pending = self.gw.call(method, params)
        try:
            return await asyncio.wait_for(pending, wait)
        except Exception as exc:  # noqa: BLE001
            log.debug("gateway call %s failed: %s", method, exc)
            return None

    async def _touch_profiles(self, profiles):
        """The gateway watches a profile's store only after a request names it, so list one chat of each."""
        for name in filter(None, profiles):
            if name not in self._touched:
                await self._ask("session.list", {"profile": name, "title": "Bot Chat", "limit": 1}, 5)
                self._touched.add(name)

    async def discover(self):
        roster = await self._ask("profiles.list", {}, 60)
        entries = (roster or {}).get("profiles", [])
        if roster is not None:
            self.labels = {}
            for entry in entries:
                if entry.get("name"):
                    self.labels[entry["name"]] = entry.get("display_name") or entry["name"]
            self._note_bot_chats(entries)
        profiles = [p.get("name") for p in entries] or [None]
        self._read_session_profiles(profiles)
        await self._touch_profiles(profiles)
        reply = await self._ask("session.active_list", {}, 60)
        self._live_ok = reply is not None
        live = (reply or {}).get("sessions", [])
        names = ("id", "session_key", "stored_session_id")
        running = [item for item in live if _is_busy(item.get("status"))]
        self._live_running = {item[key] for item in running for key in names if item.get(key)}
        for item in live:
            sid = item.get("id")
            if sid in self.attached:
                self.attached[sid]["status"] = item.get("status") or ""
            elif sid:
                await self._follow(sid, item, profiles)

    def _profile_for(self, stored, profiles):
        """The bot a live session belongs to, or None when that cannot be told yet."""
        if stored not in self.session_profile:
            self._read_session_profiles(profiles, force=True)
        found = self.session_profile.get(stored)
        found = found or self._ask_each_profile(stored, profiles)
        if found:
            return found
        named = [p for p in profiles if p]
        if len(named) > 1:
            return None            # with several bots a guess could move the chat into the wrong store
        return named[0] if named else "default"

    async def _follow(self, sid, item, profiles):
        # Do not call session.activate here. It would make this socket the attached client, so the gateway
        # would route approvals to us, and nobody here can answer them. Resume only joins a live session.
        stored = item.get("session_key") or item.get("stored_session_id") or sid
        profile = self._profile_for(stored, profiles)
        if profile is None:
            log.info("no profile lists %s yet, so it is not followed", stored[:12])
            return
        entry = {"stored": stored, "title": item.get("title") or "Hermes", "profile": profile,
                 "bot": self.labels.get(profile, profile), "source": item.get("source") or "",
                 "status": item.get("status") or ""}
        self.attached[sid] = entry
        log.info("following %s (%s, profile %s)", entry["title"], stored[:12], profile)
        await self._join(entry, stored, profile)
        waiting = await self._ask("approval.pending", {"profile": profile, "session_id": sid}, 3)
        if not isinstance(waiting, dict):
            return
        rows = waiting.get("pending") or waiting.get("approvals") or [waiting]
        for row in rows:
            if isinstance(row, dict) and row.get("request_id"):
                self.handle_request(sid, "queue-" + row["request_id"], "approval", row)

    async def _join(self, entry, stored, profile):
        """Attach next to the phone so this socket receives the session's events."""
        params = {"profile": profile, "session_id": stored, "cols": 80, "omit_messages": True}
        try:
            answer = await asyncio.wait_for(self.gw.call("session.resume", params), timeout=8)
        except Exception as exc:  # noqa: BLE001
            log.warning("could not follow %s live: %s", stored[:12], describe_error(exc))
            if "not found" not in str(exc).lower():          # a single run that the gateway has already discarded is nothing to worry about
                self._remember_la("mirror " + stored[:12], False, str(exc)[:80])
            return
        entry["mirrored"] = True
        self._remember_la("mirror " + stored[:12], True)
        info = answer.get("info") if isinstance(answer, dict) else None
        actual = (info or {}).get("profile_name")
        if actual and actual != profile:                      # the gateway knows best
            entry.update(profile=actual, bot=self.labels.get(actual, actual))
            self.session_profile[stored] = actual

    def all_idle(self):
        return not any(_is_busy(entry.get("status")) for entry in self.attached.values())

    # scheduled jobs delivered into a Bot Chat

    def _messages(self, stored, profile, limit):
        """Fetch the latest `limit` messages (person and bot only) of a session, returned oldest first."""
        route = f"/api/sessions/{urllib.parse.quote(stored)}/messages?order=latest&limit={limit}"
        if profile:
            route += "&profile=" + urllib.parse.quote(profile)
        try:
            answer = self.gw._http("GET", route)
        except Exception as exc:  # noqa: BLE001
            log.debug("could not read messages of %s: %s", stored[:12], exc)
            return []
        talk = [m for m in answer.get("messages") or [] if isinstance(m, dict) and m.get("role") in ("user", "assistant")]
        return [{"role": m["role"], "text": message_text(m), **{k: m[k] for k in CARRIED_MESSAGE_KEYS if k in m}}
                for m in talk]

    def _new_cron_reply(self, name, chat, count_before, now):
        """(chat id, job name, reply) when a Bot Chat grew by a scheduled delivery that should be pushed.
        A silent reply is remembered so nobody looks at it again."""
        chat_id = str(chat.get("resolved_id") or chat.get("id"))
        count = int(chat.get("message_count") or 0)
        marker = (chat_id, count)
        if marker in self._bot_chat_pushed or count <= count_before:
            return None
        if now < self._turn_pushed_at.get(chat_id, 0) + 20:
            return None
        thread = self._messages(chat_id, name, 6)
        last_user = max((i for i, row in enumerate(thread) if row["role"] == "user"), default=-1)
        if last_user < 0 or not thread[last_user]["text"].startswith("[Cronjob "):
            return None
        # Only a reply that comes after the newest prompt; an earlier turn's reply is never borrowed.
        after = [row for row in thread[last_user + 1:] if row["role"] == "assistant"]
        if not after or after[-1].get("tool_calls"):
            return None
        reply = after[-1]
        silent = is_silent_message(reply)
        if silent or reply["text"]:
            self._bot_chat_pushed[marker] = now
        if silent or not reply["text"]:
            return None
        job = re.match(r'\[Cronjob "([^"]+)"', thread[last_user]["text"])
        return chat_id, job[1] if job else "cron job", reply["text"]

    async def check_bot_chats(self):
        """A cron job that delivers into a Bot Chat starts a turn nothing announces. Each time a Bot Chat
        has grown and its prompt came from a cron delivery, push the reply."""
        now = time.time()
        if self._bot_chat_check_at > now - 2:
            return 0
        self._bot_chat_check_at = now
        try:
            listing = await self.gw.call("profiles.list", {})
        except Exception:  # noqa: BLE001
            return 0
        roster = listing.get("profiles", [])
        counts = {name: int(chat.get("message_count") or 0) for name, chat in self.bot_chats.items()}
        self._note_bot_chats(roster)
        sent = 0
        for name, chat in list(self.bot_chats.items()):
            fresh = self._new_cron_reply(name, chat, counts[name], now) if name in counts else None
            if fresh is None:
                continue
            chat_id, job, text = fresh
            details = {"session_id": chat_id, "profile": name, "title": "Bot Chat", "text": text[:1200], "job": job}
            self.push_all("cron", f"{self.labels.get(name, name)} · {job}", text[:300], details, collapse="cron-" + chat_id)
            log.info("%s's Bot Chat has a new result from %s", name, job)
            sent += 1
        if len(self._bot_chat_pushed) > 200:
            self._bot_chat_pushed = _forget_old(self._bot_chat_pushed, 86400, now)  # a day
        return sent

    # approvals and questions

    def handle_request(self, sid, rid, method, params):
        if rid in self.notified or not rid:
            return
        self.notified.add(rid)
        who = self.attached.get(sid, {})
        title, bot = who.get("title", "Hermes"), who.get("bot") or who.get("profile", "Hermes")
        if method == "approval":
            self._announce_approval(sid, rid, params, title, bot)
        elif method == "clarify":
            first = (params.get("questions") or [{}])[0]
            asked = params.get("question") or first.get("question") or "Hermes has a question"
            self._announce_ask(sid, rid, "question", str(asked)[:180], title, bot)
        elif method in REQUEST_PROMPTS:
            self._announce_ask(sid, rid, "input needed", str(params.get("prompt") or method), title, bot)

    def _announce_ask(self, sid, rid, label, text, title, bot):
        details = dict(self.meta(sid), request_id=rid)
        self.push_all("clarify", f"{bot} · {label}", f"{title}: {text}", details, collapse=rid)

    def _announce_approval(self, sid, rid, params, title, bot):
        stored = self.attached.get(sid, {}).get("stored", sid)
        what = str(params.get("description") or params.get("command") or "A command needs your decision")
        card = {**self.la_usage.get(sid, {}), "phase": "waiting", "detail": what[:80], "needsAttention": True}
        buzz = {"title": bot, "body": "Approval needed. Tap to answer; it waits for you."}
        covered = self.update_live_activities(stored, card, alert=buzz, runtime_id=sid)
        reached = set()
        details = dict(self.meta(sid), request_id=params.get("request_id", rid))
        self.push_all("approval", f"{bot} · approval needed", f"{title}: {what[:180]}", details,
                      collapse=rid, skip=covered, reached=reached)
        self.open_approvals[rid] = dict(sid=sid, stored=stored, req=str(params.get("request_id") or rid),
                                        at=time.time(), bot=bot, title=title, banner=reached)

    def settle_approval(self, rid, why="answered"):
        """Mark an announced approval as no longer open. The activity drops its "Needs approval" state and
        the Approve banner is swapped out silently on all devices apart from the one that replied."""
        self._approval_gone_since.pop(rid, None)
        record = self.open_approvals.pop(rid, None)
        if record is None:
            return
        sid, session = record["sid"], self.attached.get(record["sid"])
        if session and _is_busy(session.get("status")):
            self._back_to_work(sid, session)
        winner = approval_answered_by(record["req"], rid)
        replace = {dev for dev in record["banner"] if dev and dev != winner}
        if replace:
            bot = record["bot"]
            headline, line = ((f"{bot} · approval answered", "answered on another device.") if why == "answered"
                              else (bot, "no longer waiting for an answer."))
            self.push_all("settled", headline, f"{record['title']}: {line}",
                          {**self.meta(sid), "request_id": record["req"]}, collapse=rid, only=replace)
        log.info("approval %s settled (%s); %d banner(s) replaced", rid[:16], why, len(replace))

    async def settle_answered(self):
        """Check sessions holding an open approval against the gateway's pending list. Anything it no longer
        lists counts as settled, but only after two sightings of it missing, so the replying device's
        marker has time to arrive."""
        now = time.time()
        by_session = {}
        for rid, record in self.open_approvals.items():
            if now - record["at"] > 4:
                by_session.setdefault(record["sid"], []).append(rid)
        settled = 0
        for sid, rids in by_session.items():
            session = self.attached.get(sid)
            if session is None:                    # the session vanished, so nothing can wait on it
                for rid in rids:
                    self.settle_approval(rid, "gone")
                settled += len(rids)
                continue
            asked = {"profile": session.get("profile"), "session_id": sid}
            listed = pending_request_ids(await self._ask("approval.pending", asked, 3))
            if listed is None:
                continue
            for rid in rids:
                aliases = {self.open_approvals[rid]["req"], rid, rid.removeprefix("queue-")}
                if aliases & listed:
                    self._approval_gone_since.pop(rid, None)
                elif now - self._approval_gone_since.setdefault(rid, now) >= 2:
                    self.settle_approval(rid)
                    settled += 1
        return settled

    # a turn ends

    async def _recent_thread(self, sid, entry):
        """The last three or so earlier messages as short plain text, shown in the notification's reply field."""
        route = f"/api/sessions/{urllib.parse.quote(entry.get('stored', sid))}/messages?order=latest&limit=12"
        if entry.get("profile"):
            route += "&profile=" + urllib.parse.quote(entry["profile"])
        loop = asyncio.get_running_loop()
        read = loop.run_in_executor(None, self.gw._http, "GET", route)
        try:
            snapshot = await asyncio.wait_for(read, timeout=1.4)
        except Exception as exc:  # noqa: BLE001
            log.debug("could not read the thread of %s: %s", sid[:12], exc)
            return []
        lines = []
        for raw in snapshot.get("messages") or []:
            text = message_text(raw) if isinstance(raw, dict) and raw.get("role") in ("user", "assistant") else ""
            if text:
                lines.append({"role": raw["role"], "text": text[:200]})
        if lines and lines[-1]["role"] == "assistant":
            lines.pop()                                  # that is the reply the notification itself carries
        return lines[-3:]

    def _already_announced(self, key, now):
        """The same reply for the same session within a minute (a chat mirrored under two ids, a replayed
        completion) goes out once."""
        if now - self._finish_pushed.get(key, 0) < 60:
            return True
        self._finish_pushed[key] = now
        if len(self._finish_pushed) > 300:
            self._finish_pushed = _forget_old(self._finish_pushed, 600, now)
        return False

    async def _finish_turn(self, sid, entry, payload):
        """End the activity, then post the reply as a notification, unless the turn was a calm success."""
        title = entry["title"]
        bot = entry.get("bot") or entry.get("profile", "Hermes")
        failure = payload.get("error")
        stored = str(entry.get("stored", sid))
        automated = entry.get("source") == "cron" or stored.startswith("cron_")
        silent = is_silent_completion(payload, automated=automated)
        digest = hashlib.sha1(f"{payload.get('text') or ''}{failure or ''}".encode("utf-8", "replace")).hexdigest()
        now = time.time()
        repeated = self._already_announced((stored, digest, silent), now)
        self.end_live_activities(stored, "error" if failure else "done", bot=bot, runtime_id=sid,
                                 usage=payload.get("usage"))
        if repeated:
            return log.info("%s: the same finish went out a moment ago", stored[:12])
        self._turn_pushed_at[stored] = now
        if silent:
            return
        try:
            thread = await asyncio.wait_for(self._recent_thread(sid, entry), timeout=1.5)
        except asyncio.TimeoutError:
            thread = []
        collapse = f"turn-{stored}"
        if failure:
            why = str(failure)
            self.push_all("error", f"{bot} · turn failed", f"{title}: {why[:300]}",
                          {**self.meta(sid), "title": title, "text": why[:1200], "thread": thread}, collapse=collapse)
            return
        text = payload["text"] if isinstance(payload.get("text"), str) and payload["text"] else "Done"
        kind, headline = ("cron", f"{bot} · cron job finished") if automated else ("turn", bot)
        self.push_all(kind, headline, f"{title}: {text[:300]}",
                      {**self.meta(sid), "title": title, "text": text[:1200], "thread": thread}, collapse=collapse)

    async def _attach_then_handle(self, sid, event):
        await self.discover()
        if sid in self.attached:
            self.on_event(event)

    # events

    def on_event(self, event):
        kind, sid = event.get("type", ""), event.get("session_id", "")
        payload = event.get("payload") or {}
        entry = self.attached.get(sid)
        if kind in PROGRESS_EVENTS:
            self._last_running_at = time.time()
        if kind in PHASE_OF_EVENT:
            if entry:
                self._on_phase(sid, entry, PHASE_OF_EVENT[kind])
        elif kind == "session.usage":
            if entry:
                inner = payload.get("usage")
                self._on_usage(sid, entry, inner if isinstance(inner, dict) else payload)
        elif kind == "sessions.changed":
            asyncio.create_task(self.check_bot_chats())
        elif kind == "message.complete":
            self._on_complete(sid, entry, payload, event)
        elif kind == "request.cancel":
            self._on_cancel(sid, entry, payload.get("id", ""))
        elif kind == "session.title" and entry:
            entry["title"] = payload.get("title") or entry["title"]
        elif kind == "error" and entry:
            reason = str(payload.get("message", ""))[:180]
            self.push_all("error", f"{entry.get('bot') or entry.get('profile', 'Hermes')} · error",
                          f"{entry['title']}: {reason}", self.meta(sid), collapse="err-" + sid)
        elif kind == "session.reclaimed":
            self.attached.pop(payload.get("session_id", ""), None)

    def _on_complete(self, sid, entry, payload, event):
        if not entry:
            # Began since the last poll: attach now so the finish still reaches the phone.
            if sid:
                asyncio.create_task(self._attach_then_handle(sid, event))
            return
        self.la_phase.pop(sid, None)
        for rid in [r for r, rec in self.open_approvals.items() if rec["sid"] == sid]:
            self.settle_approval(rid)                  # the turn is over, so none of its approvals still wait
        counted = self.la_usage.pop(sid, None)
        self._usage_pushed.pop(sid, None)
        if counted and not isinstance(payload.get("usage"), dict):
            payload = dict(payload, usage=usage_block(counted))
        asyncio.create_task(self._finish_turn(sid, entry, payload))

    def _on_cancel(self, sid, entry, rid):
        self.notified.discard(rid)
        if rid in self.open_approvals:
            self.settle_approval(rid, "withdrawn")
        if entry and self.la_phase.get(sid):
            self._back_to_work(sid, entry)

    # the main loop

    async def _hang_up(self):
        socket = self.gw.ws
        if socket is None:
            return
        try:
            await socket.close()
        except Exception:  # noqa: BLE001
            return

    async def _reload_config(self):
        await self._hang_up()
        while True:
            _CONF.clear()
            _load_conf()
            self._conf_seen = conf_mtime()
            try:
                self.gw, self.courier = Gateway(), APNs()
                return
            except SystemExit as incomplete:
                self._beat_down(f"config incomplete: {incomplete}")
                await asyncio.sleep(self.poll)

    async def _poll_once(self):
        if code_changed():
            raise CodeChanged()
        if conf_mtime() != self._conf_seen:
            raise ConfigChanged()
        await self.discover()
        for chore in (self.reap_live_activities, self.settle_answered, self.check_bot_chats):
            try:
                outcome = chore()
                if asyncio.iscoroutine(outcome):
                    await outcome
            except Exception as exc:  # noqa: BLE001
                log.debug("%s: %s", chore.__name__, exc)
        self.answer_test_request()
        self._beat_up()

    async def _next_event(self):
        """The next gateway event, or None after a quiet poll interval."""
        waiting = self.gw.events.get()
        try:
            return await asyncio.wait_for(waiting, self.poll)
        except asyncio.TimeoutError:
            return None

    async def _serve(self):
        """Everything that happens on one connection."""
        self._beat_down("connecting…")
        await self.gw.connect()
        log.info("connected to %s", self.gw.url)
        self.attached.clear()
        polled_at = 0.0
        while True:
            if polled_at < time.time() - self.poll:
                await self._poll_once()
                polled_at = time.time()
            event = await self._next_event()
            if event is None:
                continue
            kind = event.get("type")
            if kind == "__closed__":
                raise ConnectionError("socket closed")
            if kind == "__request__":
                body = event.get("params") or {}
                self.handle_request(str(body.get("session_id") or ""), str(event.get("id") or ""),
                                    str(event.get("method") or ""), body)
                continue
            self.on_event(event)
            # Mirrored sessions stay live while a client is attached, and this socket counts as one.
            # Once things go quiet for a long time we hang up, which lets the gateway's idle reaper do its work.
            # Reconnecting mirrors the session again.
            quiet_for = time.time() - self._last_running_at
            if self.attached and quiet_for > self.release_after and self.all_idle():
                raise ReleaseIdle()

    async def run(self):
        delay = 1
        while True:
            try:
                if conf_mtime() != self._conf_seen:
                    await self._reload_config()
                await self._serve()
            except ConfigChanged:
                log.info("settings changed: loading them again")
                await self._reload_config()
                delay = 1
            except ReleaseIdle:
                log.info("quiet for %ss: letting the mirrored sessions rest", int(self.release_after))
                # Reset, or the first event after reconnecting would release again.
                self._last_running_at = time.time()
                await self._hang_up()
                delay = 1
            except CodeChanged:
                log.info("this file changed on disk: handing over to the new code")
                await self._hang_up()
                self._beat_down("reloading new code…")
                raise
            except Exception as exc:  # noqa: BLE001
                log.warning("lost the connection (%s); retrying in %ss", exc, delay)
                self._beat_down(str(exc)[:400])
                for _ in range(delay):          # back off, but stop early when the app writes new settings
                    await asyncio.sleep(1)
                    if conf_mtime() != self._conf_seen:
                        break
                delay = min(30, delay * 2)


# ───────────────────────────────── command line ─────────────────────────────


def _cmd_list(_args):
    devices = load_devices()
    print(f"{len(devices)} device(s) in {devices_dir()}")
    for device in devices:
        live = "yes" if device.get("live_activity_token") else "no"
        print(f"  {device.get('platform'):8} {device_label(device):28} {device.get('bundle_id')}"
              f"  env={device.get('apns_environment')}  live_activity={live}")
    return 0


def _cmd_test(args):
    sender = APNs()
    sender.dry_run = args.dry_run
    devices = load_devices()
    if not devices:
        sys.exit(f"no devices registered in {devices_dir()}. Open Nollie, then Settings, then Notifications, and register first")
    if not (sender.direct or any(d.get("relay") for d in devices)):
        sys.exit("neither an APNs key nor a relay registration is set up")
    note = {"aps": {"alert": {"title": "Push is working", "body": "Notifications from your gateway now arrive in the background."},
                    "sound": "default"},
            "hermes": {"kind": "test", "gateway": env("HERMES_PUSH_GATEWAY_URL").rstrip("/")}}
    delivered = sum(1 for d in devices if sender.send(d, note, collapse_id="hermes-push-test"))
    print(f"sent to {delivered}/{len(devices)} device(s)")
    return 0 if delivered == len(devices) else 1


def _cmd_serve(args):
    relay = Relay()
    relay.courier.dry_run = args.dry_run
    try:
        asyncio.run(relay.run())
    except CodeChanged:
        log.info("starting again with the updated file")
        interpreter = sys.executable
        os.execv(interpreter, [interpreter] + sys.argv)
    return 0


def main():
    _load_conf()
    parser = argparse.ArgumentParser(description="Send Hermes gateway news to the Nollie apps as notifications.")
    parser.add_argument("--list", dest="job", action="store_const", const=_cmd_list, help="show the registered devices and exit")
    parser.add_argument("--test", dest="job", action="store_const", const=_cmd_test, help="send one test alert to every device and exit")
    parser.add_argument("--dry-run", action="store_true", help="log what would be sent instead of sending it")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(format="%(asctime)s [%(levelname)s] %(message)s",
                        level=logging.DEBUG if args.verbose else logging.INFO)
    sys.exit((args.job or _cmd_serve)(args))


if __name__ == "__main__":
    main()
