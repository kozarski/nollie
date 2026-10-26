"""Paying with a saved card: a helper at a checkout asks to pay, the person says yes, and Nollie on the
Mac fills the card into the helper's computer and presses Return.

Card numbers never come here. They live only in the Mac's Keychain, behind Touch ID or the Mac's
password for every read, and the security code is typed by the person on the Mac each time and
never kept. The rules that decide whether a payment asks (the first payment on each site always
does) are the Mac's, kept where a helper can't change them; this add-on only carries the request.
It keeps four small things in the main bot's home, under ``nollie-workflow/payments/`` (folders 0700,
files 0600):

- ``cards.json``: the cards as the Mac app last sent them: brand, last four digits, the name on the
  card. Never a number, an expiry date or a security code.
- ``bots.json``: which helpers may pay with the person's cards (all off to start).
- ``requests/<id>.json``: one payment while it is open: bot, site, total, currency, computer, state.
- ``history.jsonl``: one line per payment: when, bot, site, card ending, total, outcome.

What the helper is told is fixed words: paid, declined, or why not. At most "Visa ending 4242".

While a card is typed, and until the Mac sees the number is gone from the screen, pictures of every
computer pause by the same rule as saved sign-ins (``sign_ins.typing_now`` reads these requests too).
"""
from __future__ import annotations

import contextlib
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import re
import secrets
import time

from .sign_ins import FILL_TAIL, SETTLE, normalize_site, valid_computer
from .workflow_core import atomic_write, file_lock

FOLDER = "payments"
MAX_CARDS = 20
KEEP_HISTORY_DAYS = 90
MAX_HISTORY_LINES = 2000
REQUEST_LIFETIME = 3600
# For the Mac to look at the rules and word the card.
MAC_WAIT = 20.0
# For the person to type the security code on the Mac after a yes (they may have answered on the iPhone).
PAY_WAIT = 180.0
# Once the Mac has started typing, so a slow computer is not cut off halfway.
FILL_GRACE = 60.0
POLL = 0.5
MAX_TOTAL = Decimal("100000")

# waiting: for the Mac's rules. prepared: the Mac worded it and said whether it asks. approved: the person
# said yes (or the Mac's quick-pay rule spared the card); the Mac asks for the security code. filling: the
# Mac is typing. showing: typed, but the card number is still on the screen. done: over.
STATES = ("waiting", "prepared", "approved", "filling", "showing", "done")
# States in which a card number may be on a screen right now: pictures pause.
TYPING = ("filling", "showing")
REQUEST_ID = re.compile(r"[0-9a-f]{32}\Z")
CURRENCY = re.compile(r"[A-Z]{3}\Z")
LAST4 = re.compile(r"[0-9]{4}\Z")
BRANDS = ("visa", "mastercard", "amex", "discover", "diners", "jcb", "unionpay", "maestro", "card")
BRAND_NAMES = {"visa": "Visa", "mastercard": "Mastercard", "amex": "American Express", "discover": "Discover",
               "diners": "Diners Club", "jcb": "JCB", "unionpay": "UnionPay", "maestro": "Maestro", "card": "Card"}
# What the Mac may report. A reason is one of these words, never free text.
REFUSALS = ("private", "not_allowed", "no_card", "currency", "bad_total", "bad_site", "unknown_card")
MAC_OUTCOMES = ("paid", "failed", "cancelled")
MAC_REASONS = ("total_not_shown", "changed", "computer_unavailable", "fill_failed", "touch_id", "not_saved_here",
               "private", "fill_unavailable")
# Ask first's own rule, so the app shows its buy card and Face ID guards the yes:
# plugin_rule:nollie-ask-first:buy:<id>.
RULE_PREFIX = "nollie-ask-first:buy:"
WORDS_LIMIT = 400


class Conflict(Exception):
    """The request is not in a state that allows this step (answered, finished or gone)."""


def clean_total(raw):
    """A positive amount with at most two decimal places, as text ("48.99"), or None."""
    if isinstance(raw, bool) or not isinstance(raw, (str, int, float)):
        return None
    text = str(raw).strip().replace(",", "") if isinstance(raw, str) else repr(raw)
    if not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,2})?", text):
        return None
    try:
        amount = Decimal(text)
    except InvalidOperation:
        return None
    if amount <= 0 or amount > MAX_TOTAL:
        return None
    return f"{amount:.2f}"


def clean_currency(raw):
    text = raw.strip().upper() if isinstance(raw, str) else ""
    return text if CURRENCY.fullmatch(text) else None


def clean_last4(raw):
    """The last four digits of the card the helper named ("4242", "Visa ending 4242"), or None."""
    if not isinstance(raw, str):
        return None
    digits = re.findall(r"[0-9]{4}", raw)
    return digits[-1] if digits and LAST4.fullmatch(digits[-1]) else None


def label(card):
    return f"{BRAND_NAMES.get(card.get('brand'), 'Card')} ending {card.get('last4')}"


class Store:
    """The add-on's side of paying with saved cards, shared by the tools (in the gateway) and the routes
    (in the dashboard) through files under one lock."""

    def __init__(self, main_home, clock=time.time):
        self.root = Path(main_home) / "nollie-workflow" / FOLDER
        self.clock = clock

    @contextlib.contextmanager
    def _locked(self):
        for path in (self.root.parent, self.root, self.root / "requests"):
            if path.is_symlink():
                raise ValueError("a payments folder is a link")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with file_lock(self.root / "payments.lock"):
            yield

    def _document(self, name, limit=64 * 1024):
        path = self.root / name
        try:
            if path.is_symlink() or path.stat().st_size > limit:
                raise ValueError(f"{name} is not readable")
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return None
        except UnicodeDecodeError:
            raise ValueError(f"{name} is not readable") from None
        if not isinstance(document, dict) or document.get("version") != 1:
            raise ValueError(f"{name} is not valid")
        return document

    # Cards, as labels only ---------------------------------------------------------------

    @staticmethod
    def clean_cards(cards):
        if not isinstance(cards, list) or len(cards) > MAX_CARDS:
            raise ValueError(f"Send a list of at most {MAX_CARDS} cards.")
        cleaned = []
        for card in cards:
            if not isinstance(card, dict) or set(card) - {"id", "brand", "last4", "holder"}:
                raise ValueError("Each card is an id, a brand, the last four digits and a name.")
            card_id, brand, last4, holder = card.get("id"), card.get("brand"), card.get("last4"), card.get("holder", "")
            if not isinstance(card_id, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", card_id):
                raise ValueError("Each card needs an id.")
            if brand not in BRANDS or not isinstance(last4, str) or not LAST4.fullmatch(last4):
                raise ValueError("Each card needs a brand and its last four digits.")
            holder = " ".join(holder.split())[:80] if isinstance(holder, str) else ""
            if re.search(r"[0-9]{5,}", holder):
                raise ValueError("A name can't hold a number.")
            cleaned.append({"id": card_id, "brand": brand, "last4": last4, "holder": holder})
        return cleaned

    def cards(self):
        document = self._document("cards.json")
        cards = document.get("cards") if document else []
        return self.clean_cards(cards)

    def save_cards(self, cards):
        cleaned = self.clean_cards(cards)
        with self._locked():
            atomic_write(self.root / "cards.json", {"version": 1, "cards": cleaned})
        return cleaned

    # Which helpers may pay -----------------------------------------------------------------

    def bots(self):
        """The helpers whose switch is on. A damaged file raises: fail closed."""
        document = self._document("bots.json")
        if document is None:
            return []
        bots = document.get("bots")
        if not isinstance(bots, list) or not all(isinstance(b, str) for b in bots):
            raise ValueError("bots.json is not valid")
        return sorted(set(bots))

    def allowed(self, bot):
        try:
            return bot in self.bots()
        except (OSError, ValueError):
            return False

    def set_bot(self, bot, on):
        if not isinstance(on, bool):
            raise ValueError("Send on as true or false.")
        with self._locked():
            bots = set(self.bots())
            (bots.add if on else bots.discard)(bot)
            atomic_write(self.root / "bots.json", {"version": 1, "bots": sorted(bots)})
        return on

    # Requests ---------------------------------------------------------------------------

    def _path(self, request_id):
        if not isinstance(request_id, str) or not REQUEST_ID.match(request_id):
            raise LookupError(request_id)
        return self.root / "requests" / (request_id + ".json")

    def _read(self, request_id):
        path = self._path(request_id)
        try:
            if path.is_symlink() or path.stat().st_size > 16 * 1024:
                raise LookupError(request_id)
            record = json.loads(path.read_text())
        except (FileNotFoundError, ValueError, UnicodeDecodeError):
            raise LookupError(request_id) from None
        if not isinstance(record, dict) or record.get("id") != request_id or record.get("state") not in STATES:
            raise LookupError(request_id)
        return record

    def _write(self, record):
        record["updated_at"] = int(self.clock())
        atomic_write(self._path(record["id"]), record)
        return dict(record)

    def create(self, bot, site, total, currency, computer, card=None):
        now = int(self.clock())
        record = {"version": 1, "id": secrets.token_hex(16), "bot": bot, "site": site, "total": total,
                  "currency": currency, "card": card, "computer": computer, "state": "waiting", "words": None,
                  "card_label": None, "ask": None, "approver": None, "outcome": None, "reason": None,
                  "created_at": now, "updated_at": now}
        with self._locked():
            self._prune()
            return self._write(record)

    def get(self, request_id):
        with self._locked():
            return self._read(request_id)

    def open_requests(self):
        folder = self.root / "requests"
        found = []
        with self._locked():
            self._prune()
            if folder.is_dir():
                for path in folder.glob("*.json"):
                    with contextlib.suppress(LookupError):
                        record = self._read(path.stem)
                        if record["state"] != "done":
                            found.append(record)
        return sorted(found, key=lambda r: (r["created_at"], r["id"]))

    def _step(self, request_id, allowed, change):
        with self._locked():
            record = self._read(request_id)
            if record["state"] not in allowed or self.clock() - record["created_at"] > REQUEST_LIFETIME:
                raise Conflict(record["state"])
            change(record)
            return self._write(record)

    def prepare(self, request_id, words, card_label, ask):
        """The Mac's words for the card, the card it will use and whether its rules ask the person."""
        if not isinstance(words, str) or not words.strip() or len(words) > WORDS_LIMIT:
            raise ValueError("Send the card's words.")
        if not isinstance(card_label, str) or not re.fullmatch(r"[A-Za-z ]{2,24} ending [0-9]{4}", card_label):
            raise ValueError("Send the card as “Visa ending 4242”.")
        if not isinstance(ask, bool):
            raise ValueError("Send ask as true or false.")
        return self._step(request_id, ("waiting",),
                          lambda r: r.update(state="prepared", words=words.strip(), card_label=card_label, ask=ask))

    def refuse(self, request_id, reason, expected=None):
        """The Mac's rules said no before anyone was asked. ``expected``: the currency the person pays in."""
        if reason not in REFUSALS:
            raise ValueError("unknown reason")
        if expected is not None and clean_currency(expected) != expected:
            raise ValueError("Send the expected currency as a three-letter code.")
        return self._step(request_id, ("waiting",), lambda r: r.update(state="done", outcome="refused",
                                                                       reason=reason, expected=expected))

    def approve(self, request_id, approver):
        return self._step(request_id, ("prepared",), lambda r: r.update(state="approved", approver=approver))

    def start(self, request_id):
        """The Mac begins typing. Only once, and only while the tool still waits."""
        return self._step(request_id, ("approved",), lambda r: r.update(state="filling"))

    def report(self, request_id, outcome, reason=None, showing=False):
        """The Mac's answer after it tried. ``showing``: typed, but the number is still on the screen."""
        if outcome not in MAC_OUTCOMES or (reason is not None and reason not in MAC_REASONS):
            raise ValueError("unknown outcome")
        if not isinstance(showing, bool):
            raise ValueError("Send showing as true or false.")

        def change(record):
            if outcome == "paid" and record["state"] != "filling":
                raise Conflict(record["state"])  # nothing was typed, so nothing was paid
            if showing and record["state"] == "filling":
                record.update(state="showing", outcome=outcome, reason=reason)
            else:
                record.update(state="done", outcome=outcome, reason=reason, quiet_until=self.clock() + SETTLE)
        return self._step(request_id, ("approved", "filling"), change)

    def clear(self, request_id):
        """The Mac sees the card number is gone from the screen: pictures may resume after the pause."""
        return self._step(request_id, ("showing",), lambda r: r.update(state="done", quiet_until=self.clock() + SETTLE))

    def close(self, request_id, outcome):
        """The tool gives up on a request that has not finished (a no, no answer, a timeout)."""
        with self._locked():
            record = self._read(request_id)
            if record["state"] in ("done", "showing"):
                return record
            tail = FILL_TAIL if record["state"] == "filling" else SETTLE
            record.update(state="done", outcome=outcome, quiet_until=self.clock() + tail)
            return self._write(record)

    def expire_unless_filling(self, request_id):
        with self._locked():
            record = self._read(request_id)
            if record["state"] in ("prepared", "approved"):
                record.update(state="done", outcome="expired", quiet_until=self.clock() + SETTLE)
                return self._write(record)
            return record

    def _prune(self):
        folder = self.root / "requests"
        if not folder.is_dir():
            return
        now = self.clock()
        for path in folder.glob("*.json"):
            with contextlib.suppress(OSError, ValueError, UnicodeDecodeError, AttributeError):
                if path.is_symlink():
                    path.unlink()
                    continue
                stamp = json.loads(path.read_text()).get("updated_at")
                if not isinstance(stamp, int) or now - stamp > REQUEST_LIFETIME * 2:
                    path.unlink()

    # History ----------------------------------------------------------------------------

    def record_use(self, record, outcome):
        last4 = clean_last4(record.get("card_label") or "")
        entry = {"v": 1, "at": int(self.clock()), "bot": record.get("bot"), "site": record.get("site"),
                 "total": record.get("total"), "currency": record.get("currency"), "card": last4,
                 "outcome": outcome, "approver": record.get("approver")}
        path = self.root / "history.jsonl"
        with self._locked():
            if path.is_symlink():
                raise ValueError("the history is a link")
            try:
                lines = [line for line in path.read_text().splitlines() if line.strip()]
            except FileNotFoundError:
                lines = []
            lines.append(json.dumps(entry, separators=(",", ":")))
            cutoff = self.clock() - KEEP_HISTORY_DAYS * 86400
            kept = [line for line in lines if _line_time(line) >= cutoff][-MAX_HISTORY_LINES:]
            temporary = path.with_name(".history-" + secrets.token_hex(4))
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(fd, "w") as handle:
                    handle.write("\n".join(kept) + "\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, path)
            finally:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary)
        return entry

    def history(self, days=30, private=frozenset()):
        path = self.root / "history.jsonl"
        cutoff = self.clock() - days * 86400
        with self._locked():
            if path.is_symlink():
                raise ValueError("the history is a link")
            try:
                lines = path.read_text().splitlines()
            except FileNotFoundError:
                lines = []
        entries = []
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if (isinstance(entry, dict) and isinstance(entry.get("at"), int) and entry["at"] >= cutoff
                    and str(entry.get("bot", "")).lower() not in private):
                entries.append({k: entry.get(k) for k in ("at", "bot", "site", "total", "currency", "card", "outcome",
                                                          "approver")})
        return list(reversed(entries))[:200]


def _line_time(line):
    try:
        value = json.loads(line).get("at")
        return value if isinstance(value, int) else 0
    except (ValueError, AttributeError):
        return 0


# The tools --------------------------------------------------------------------------------

DESCRIPTION = (
    "Pay at a checkout with a card the person saved in Nollie on their Mac. Use it on your own computer when the "
    "checkout shows the total and the card form. First click the card number box, then call this with the site, "
    "the total and the currency exactly as the page shows them. The person is asked (the first payment on each site "
    "always asks), types the card's security code on their Mac, and Nollie fills in the card number, expiry date and "
    "security code and presses Return. Nollie checks the total is on the screen first. You are never told the card "
    "number, and you must never ask the person for card details in the chat. While Nollie types, and until the number "
    "is gone from the screen, screenshots and actions on computers are paused. Answers: paid, declined, or "
    "not_paid with the reason."
)
SCHEMA = {"name": "request_payment", "description": DESCRIPTION, "parameters": {
    "type": "object", "additionalProperties": False,
    "properties": {
        "site": {"type": "string", "description": "The site's address as shown in the address bar, like shop.example.com."},
        "total": {"type": "string", "description": "The total to pay, as the checkout shows it, like 48.99."},
        "currency": {"type": "string", "description": "The currency of the total, as a three-letter code like GBP."},
        "computer": {"type": "string", "description": "Your Cua computer's name, like local:dev."},
        "card": {"type": "string", "description": "Which saved card, like “Visa ending 4242”. Leave out for the first."},
    }, "required": ["site", "total", "currency", "computer"]}}

CARDS_DESCRIPTION = ("The cards the person saved in Nollie for paying at checkouts: “Visa ending 4242” and the name on "
                     "the card, if a form asks for it. Never the number. Pay with request_payment.")
CARDS_SCHEMA = {"name": "payment_cards", "description": CARDS_DESCRIPTION, "parameters": {
    "type": "object", "additionalProperties": False, "properties": {}, "required": []}}


def result(status, message, **extra):
    return json.dumps({"status": status, "message": message, **extra}, ensure_ascii=False)


HELD = "Held for the person's yes"
MESSAGES = {
    "private": "Paying with saved cards isn't available to this bot.",
    "not_allowed": "Paying with saved cards is off for this helper. The person can turn it on in Bot settings, Apps.",
    "no_card": "There's no saved card yet. Ask the person to add one in Nollie on their Mac: Settings, Cards. Never "
               "ask for card details in the chat.",
    "unknown_card": "There's no saved card with those last four digits. Call payment_cards to see the saved ones.",
    "unattended": HELD + ": Nollie asks the person before paying, and nobody can answer in this run. Nothing was paid. "
                         "Say in your report that the payment is waiting for them.",
    "bypassed": "Not paid: Nollie asks the person before paying, and approvals are switched off for this bot, so "
                "nobody could be asked.",
    "bad_site": "Send the site's address, like shop.example.com.",
    "bad_total": "Send the total as a number with up to two decimals, like 48.99.",
    "bad_currency": "Send the currency as a three-letter code, like GBP.",
    "bad_computer": "Say which computer the checkout is on: your Cua computer's name, like local:dev.",
    "mac_computer": "Nollie can't fill a card on this Mac. Pay on your own computer, or ask the person to pay themselves.",
    "currency": "The person pays in {expected}, and this total is in {currency}, so nothing was asked or paid. Tell the "
                "person.",
    "no_mac": "Nollie on the Mac didn't answer. It may be closed. Ask the person to open Nollie on their Mac.",
    "busy": "The payment couldn't be started right now. Try again in a moment.",
    "declined": "The person said no, so nothing was paid. Don't try again unless they ask.",
    "no_answer": "Nobody answered, so nothing was paid. Don't try again unless the person asks.",
    "expired": "Nobody confirmed on the Mac, so nothing was filled in. Don't try again unless the person asks.",
    "cancelled": "The person didn't confirm on the Mac, so nothing was filled in.",
    "interrupted": "The payment was stopped. Something may have been typed already; take a screenshot to check.",
    "total_not_shown": "The checkout didn't show {amount} when Nollie looked, so nothing was filled in. Check the total "
                       "and ask again with what the page shows.",
    "changed": "The payment changed after the person was asked, so nothing was filled in.",
    "computer_unavailable": "Nollie couldn't reach that computer. Check it's running and that the name is right.",
    "fill_failed": "Nollie couldn't finish filling in the card. Take a screenshot and tell the person.",
    "fill_unavailable": "Nollie can't fill a card into this computer. Ask the person to pay themselves.",
    "touch_id": "The Mac couldn't confirm it was the person, so nothing was filled in.",
    "not_saved_here": "That card isn't saved on the Mac any more. Ask the person to check Settings, Cards.",
}


def money(total, currency):
    symbols = {"GBP": "£", "EUR": "€", "USD": "$"}
    return f"{symbols[currency]}{total}" if currency in symbols else f"{total} {currency}"


def paid(record):
    text = (f"Nollie filled in {record['card_label']} and pressed Return to pay {money(record['total'], record['currency'])} "
            f"on {record['site']}. Take a screenshot to check the page.")
    if record.get("state") == "showing":
        text += (" The card number is still on the screen, so pictures stay paused until it's gone. Tell the "
                 "person; they can look at your computer from the chat.")
    return text


def _doubt(check):
    """A check that can't answer counts as yes: nobody can be asked, so nothing is paid."""
    try:
        return bool(check())
    except Exception:
        return True


def handle(args, *, store, bot, is_private, unattended, bypassed, ask, interrupted=lambda: False, clock=time.monotonic, sleep=time.sleep, waiting=contextlib.nullcontext):
    """One request_payment call. Every injected piece is Hermes's in the real tool and a fake in tests."""
    try:
        if is_private():
            return result("refused", MESSAGES["private"])
    except Exception:
        return result("refused", MESSAGES["private"])  # a damaged Private list refuses everyone
    if not store.allowed(bot):
        return result("not_paid", MESSAGES["not_allowed"])
    if _doubt(unattended):
        return result("blocked", MESSAGES["unattended"])
    if _doubt(bypassed):
        return result("blocked", MESSAGES["bypassed"])
    args = args if isinstance(args, dict) else {}
    site = normalize_site(args.get("site"))
    if site is None:
        return result("not_paid", MESSAGES["bad_site"])
    total = clean_total(args.get("total"))
    if total is None:
        return result("not_paid", MESSAGES["bad_total"])
    currency = clean_currency(args.get("currency"))
    if currency is None:
        return result("not_paid", MESSAGES["bad_currency"])
    computer = valid_computer(args.get("computer"))
    if computer is None:
        return result("not_paid", MESSAGES["bad_computer"])
    if computer == "mac":
        return result("not_paid", MESSAGES["mac_computer"])
    card = clean_last4(args.get("card")) if args.get("card") else None
    try:
        cards = store.cards()
        if not cards:
            return result("not_paid", MESSAGES["no_card"])
        if card and not any(c["last4"] == card for c in cards):
            return result("not_paid", MESSAGES["unknown_card"])
        record = store.create(bot, site, total, currency, computer, card)
    except (OSError, ValueError):
        return result("not_paid", MESSAGES["busy"])
    request_id = record["id"]

    def finish(outcome, status, message):
        current = {}
        with contextlib.suppress(Exception):
            current = store.get(request_id)
            store.record_use(current, outcome)
        # At most "Visa ending 4242": the Mac's label, checked when it was stored.
        extra = {"card": current["card_label"]} if current.get("card_label") else {}
        return result(status, message, **extra)

    def wait(states, seconds, beat=None):
        deadline = clock() + seconds
        while True:
            try:
                found = store.get(request_id)
            except (LookupError, OSError, ValueError):
                return None
            if found["state"] in states or clock() >= deadline:
                return found
            if callable(beat):
                beat()
            sleep(POLL)

    # The Mac's rules: refuse, or word the card and say whether it asks.
    with waiting() as beat:
        record = wait(("prepared", "done"), MAC_WAIT, beat)
    if record is None or record["state"] == "waiting":
        with contextlib.suppress(Exception):
            store.close(request_id, "no_mac")
        return finish("no_mac", "not_paid", MESSAGES["no_mac"])
    if record["state"] == "done":
        reason = record.get("reason") or "busy"
        if reason == "currency":
            text = MESSAGES["currency"].format(expected=record.get("expected") or "another currency", currency=currency)
            return finish("refused", "not_paid", text)
        return finish("refused", "not_paid", MESSAGES.get(reason, MESSAGES["busy"]))

    if record["ask"]:
        try:
            decision = ask(record["words"], RULE_PREFIX + request_id)
        except Exception:
            decision = {"approved": False, "outcome": "notify_failed"}
        if not isinstance(decision, dict) or decision.get("approved") is not True:
            quiet = isinstance(decision, dict) and decision.get("outcome") in ("timeout", "cancelled", "notify_failed")
            outcome = "no_answer" if quiet else "declined"
            with contextlib.suppress(Exception):
                store.close(request_id, outcome)
            return finish(outcome, "declined", MESSAGES[outcome])
    try:
        store.approve(request_id, "card" if record["ask"] else "quick")
    except (Conflict, LookupError, OSError, ValueError):
        with contextlib.suppress(Exception):
            store.close(request_id, "failed")
        return finish("failed", "not_paid", MESSAGES["busy"])

    # The Mac asks for the security code, checks the total is on the screen, then types.
    deadline = clock() + PAY_WAIT
    grace_used = False
    with waiting() as beat:
        while True:
            try:
                record = store.get(request_id)
            except (LookupError, OSError, ValueError):
                return finish("failed", "not_paid", MESSAGES["busy"])
            if record["state"] in ("done", "showing"):
                break
            if interrupted():
                with contextlib.suppress(Exception):
                    record = store.close(request_id, "interrupted")
                break
            if clock() >= deadline:
                with contextlib.suppress(Exception):
                    record = store.expire_unless_filling(request_id)
                if record["state"] == "filling" and not grace_used:
                    grace_used = True
                    deadline = clock() + FILL_GRACE
                    continue
                if record["state"] not in ("done", "showing"):
                    with contextlib.suppress(Exception):
                        record = store.close(request_id, "expired")
                break
            if callable(beat):
                beat()
            sleep(POLL)

    outcome, reason = record.get("outcome"), record.get("reason")
    if outcome == "paid" or grace_used or outcome == "interrupted":
        # The page may still show what was typed: wait out the pause before the helper looks.
        settle_until = clock() + SETTLE
        while clock() < settle_until:
            sleep(min(POLL, max(0.0, settle_until - clock())))
        with contextlib.suppress(Exception):
            record = store.get(request_id)
    if outcome == "paid":
        return finish("paid", "paid", paid(record))
    if outcome == "cancelled":
        return finish("cancelled", "declined", MESSAGES["cancelled"])
    if outcome in ("expired", "interrupted"):
        return finish(outcome, "not_paid", MESSAGES[outcome])
    text = MESSAGES.get(reason or "", MESSAGES["fill_failed"])
    if reason == "total_not_shown":
        text = text.format(amount=money(record["total"], record["currency"]))
    return finish("failed", "not_paid", text)


def list_cards(*, store, bot, is_private):
    try:
        if is_private():
            return result("refused", MESSAGES["private"])
    except Exception:
        return result("refused", MESSAGES["private"])
    if not store.allowed(bot):
        return result("off", MESSAGES["not_allowed"])
    try:
        cards = store.cards()
    except (OSError, ValueError):
        return result("error", MESSAGES["busy"])
    if not cards:
        return result("none", MESSAGES["no_card"], cards=[])
    return result("ok", None, cards=[{"card": label(c), "name_on_card": c["holder"] or None} for c in cards])


# Hermes glue -----------------------------------------------------------------------------

def hermes_ask(description, rule):
    """Hermes's own human gate: the same card, alert and Allow once / Deny as any approval."""
    from tools.approval import request_tool_approval
    return request_tool_approval("request_payment", description, rule_key=rule)


def register(ctx, main_home, profile, is_private):
    """request_payment and payment_cards, in the nollie_payments toolset, for a bot that is not private.
    Shown only while the person's "Can pay with my cards" switch is on for this helper."""
    from .ask_first import hermes_bypassed, hermes_unattended
    from .sign_ins import hermes_interrupted, hermes_waiting
    store = Store(main_home)
    unattended = hermes_unattended(ctx)

    def shown():
        try:
            return not is_private() and store.allowed(profile)
        except Exception:
            return False

    def pay(args, session_id=None, **_):
        return handle(args, store=store, bot=profile, is_private=is_private, unattended=unattended,
                      bypassed=lambda: hermes_bypassed(session_id), ask=hermes_ask, interrupted=hermes_interrupted,
                      waiting=hermes_waiting)

    def cards(args=None, **_):
        return list_cards(store=store, bot=profile, is_private=is_private)

    ctx.register_tool(name="request_payment", toolset="nollie_payments", schema=SCHEMA, handler=pay,
                      check_fn=shown, description=DESCRIPTION)
    ctx.register_tool(name="payment_cards", toolset="nollie_payments", schema=CARDS_SCHEMA, handler=cards,
                      check_fn=shown, description=CARDS_DESCRIPTION)
