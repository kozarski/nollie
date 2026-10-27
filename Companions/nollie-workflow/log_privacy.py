"""Keeps the words of chats out of Hermes's logs.

Hermes has no setting for it: ``agent.log`` keeps the first 80 characters of each message, ``gateway.log``
the first 80 of each message from a chat app (and of the one it replies to), and schedules, pictures and
vision the first 100 or 80 of their prompts. This installs one log record factory for the whole process,
ahead of every log file and handler, that writes "[left out]" in their place:

- each line Hermes writes words into, by its exact template (checked against the pinned Hermes source in
  the tests), and any other template with a ``msg=%r``;
- anything else that quotes 16 or more characters from the start of a recent message or reply, as the
  ``pre_llm_call`` and ``post_llm_call`` hooks saw them. Those texts are held in memory only, a few at a
  time, and never written anywhere.

Stdlib only. It never raises into Hermes: a record it can't read is left as it was.
"""
from __future__ import annotations

from collections import deque
import logging
import re
import threading

LEFT_OUT = "[left out]"
# Template -> the %-arguments that may carry words: every log call in Hermes v0.22.2 that passes a slice of a
# message, prompt, reply or body (test_log_privacy finds them in the pinned source and checks each is here).
TEMPLATES = {
    'Buzz: localized %d inbound media attachment(s) for message %s': (1,),
    'Buzz: not localizing %d media reference(s) in message %s — sender %s… is not explicitly authorized': (1,),
    'Buzz: reaction add failed for message %s in %s — %s': (0,),
    'Buzz: reaction failed for message %s': (0,),
    'Codex response contains leaked tool-call text in assistant content (no structured function_call items). Treating as incomplete so the continuation path can re-elicit a proper tool call. Leaked snippet: %r': (0,),
    'Degenerate final: %d-char fragment %r ended the turn after %d tool result(s) — re-prompting (%d/2)': (1,),
    'Delivered /steer to agent after tool batch (%d chars) as new user message: %s': (1,),
    'Dropped silence-narration outbound to %s (chat=%s): %r': (2,),
    'Editing image with %s (%s) — %d source image(s), prompt: %s': (3,),
    "Enqueued leftover /steer behind pending message for session %s: '%s...'": (1,),
    'Forwarded update prompt to %s: %s': (1,),
    'Generating image with %s (%s) — prompt: %s': (2,),
    "MCP server '%s' elicitation request: %s": (1,),
    'MM API %s %s → %s: %s': (3,),
    'MM file upload → %s: %s': (1,),
    'Prompt on session %s: %s': (1,),
    'Prompt: %s': (0,),
    'Proxy error (%d) from %s: %s': (2,),
    'Signal: message from %s in %s: %s': (2,),
    'SimpleX: message from %s in %s: %s': (2,),
    'User prompt: %s': (0,),
    '[%s] C2C message: id=%s content=%r attachments=%s': (2,),
    '[%s] Message from %s in %s: %s': (3,),
    '[%s] Message on topic %s: %s': (2,),
    '[%s] STT: using QQ asr_refer_text: %r': (1,),
    '[%s] Send failed HTTP %d: %s': (2,),
    '[%s] Sending image: %s (alt=%s)': (2,),
    '[%s] _send_emotion: %s %s on msg=%s': (3,),
    '[%s] stderr: %s': (1,),
    '[Feishu-Comment] API >>> %s %s paths=%s queries=%s body=%s': (4,),
    '[Feishu-Comment] Agent response (%d chars): %s': (1,),
    '[Feishu-Comment] Whole timeline: %d entries, current_idx=%d, self_idx=%d, text=%s': (3,),
    '[Feishu-Comment] _run_comment_agent: done api_calls=%d response_len=%d response=%s': (2,),
    '[Feishu-Comment] add_whole_comment: file_token=%s text=%s': (1,),
    '[Feishu-Comment] reply_to_comment: comment_id=%s text=%s': (1,),
    '[Feishu] Inbound %s message received: id=%s type=%s chat_id=%s sender=%s:%s text=%r media=%d': (6,),
    '[Slack] response_url POST returned %s: %s': (1,),
    '[msgraph_webhook] Response for %s: %s': (1,),
    '[sms] inbound from %s -> %s: %s': (2,),
    '[webhook] Response for %s: %s': (1,),
    '[webhook] direct-deliver log-only: %s': (0,),
    "browser '%s' failed (rc=%s): %s": (2,),
    'conversation turn: session=%s model=%s provider=%s platform=%s history=%d msg=%r': (5,),
    'conversation turn: session=%s model=%s provider=%s platform=%s history=%d msg=%r origin=%s': (5,),
    'inbound message: platform=%s user=%s chat=%s msg=%r reply_to_id=%s reply_to_text=%r': (3, 5),
    'photon: device-token unexpected status %s: %s': (1,),
    'scale-to-zero: flaps suspend rejected: %s %s': (1,),
    'slow session search: path=%s elapsed=%.0fms rows=%s query=%r': (3,),
    'status_callback suppressed for %s/%s: %s': (2,),
    'tool error body truncated for context (%d chars): %s': (1,),
}
_CONVERSION = re.compile(r"%(?:\([^)]*\))?[-#0 +]*(?:\*|\d+)?(?:\.(?:\*|\d+))?[hlL]?([diouxXeEfFgGcrsa%])")
WORDS_BEFORE = ("msg=",)
SHORTEST = 16
KEEP = 32
_MARK = "_nollie_log_privacy"

_lock = threading.Lock()
_recent = deque(maxlen=KEEP)


def _plain(text):
    return " ".join(str(text).split())


def word_arguments(template):
    """Which %-arguments of a template carry words: a known template's, else any after ``msg=``."""
    known = TEMPLATES.get(template)
    if known is not None:
        return known
    found, index, start = [], 0, 0
    for match in _CONVERSION.finditer(template):
        if match.group(1) == "%":
            continue
        if template[start:match.start()].endswith(WORDS_BEFORE):
            found.append(index)
        index += 1
        start = match.end()
    return tuple(found)


def remember(text):
    """A message or reply, so a later line that quotes it is caught. Only its start is kept."""
    text = _plain(text or "")
    if len(text) >= SHORTEST:
        with _lock:
            _recent.append(text[:200])


def _scrub_quotes(message):
    with _lock:
        texts = list(_recent)
    if not texts or len(message) < SHORTEST:
        return message
    plain = _plain(message)
    changed = False
    for text in texts:
        at = plain.find(text[:SHORTEST])
        while at >= 0:
            length = SHORTEST
            while at + length < len(plain) and length < len(text) and plain[at + length] == text[length]:
                length += 1
            plain = plain[:at] + LEFT_OUT + plain[at + length:]
            changed = True
            at = plain.find(text[:SHORTEST], at + len(LEFT_OUT))
    return plain if changed else message


def scrub(record):
    """The record with its words left out. Changes it in place and returns it."""
    try:
        template, args = record.msg, record.args
        if isinstance(template, str) and isinstance(args, tuple) and args:
            words = word_arguments(template)
            if words:
                record.args = tuple(LEFT_OUT if i in words else arg for i, arg in enumerate(args))
        if _recent:
            message = record.getMessage()
            cleaned = _scrub_quotes(message)
            if cleaned is not message:
                record.msg, record.args = cleaned, ()
    except Exception:
        pass
    return record


def install():
    """Once per process, around whatever factory is there now (Hermes's session tag included)."""
    with _lock:
        current = logging.getLogRecordFactory()
        if getattr(current, _MARK, False):
            return False

        def factory(*args, **kwargs):
            return scrub(current(*args, **kwargs))

        setattr(factory, _MARK, True)
        # Hermes installs its own factory once, guarded by this marker; it runs inside this one.
        if getattr(current, "_hermes_session_injector", False):
            factory._hermes_session_injector = True
        logging.setLogRecordFactory(factory)
        return True


def register(ctx):
    """The two hooks that let it recognise a message quoted later."""
    def before(user_message=None, **_):
        remember(user_message if isinstance(user_message, str) else "")

    def after(user_message=None, assistant_response=None, **_):
        remember(user_message if isinstance(user_message, str) else "")
        remember(assistant_response if isinstance(assistant_response, str) else "")

    ctx.register_hook("pre_llm_call", before)
    ctx.register_hook("post_llm_call", after)
