"""Polite limits shared by every bot on this Mac, kept in file-locked state.

Services (search tiers and reference sources): about one request a second each, a soft daily
cap under the free tier, longer pauses after slow-down replies, and a capped service rests
until the next local day. Sites: a few seconds between requests to the same host, longer when
robots.txt asks, and a rest after a site says to slow down.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path
import time

from .state import locked_json, read_json, load_settings

# Soft caps sit under each free tier. Exa's keyless tier allows about 50 a day; the others do
# not publish an anonymous daily number, so these stay deliberately low and can be changed in
# settings.json ("services": {"parallel": {"daily": 60}}).
SERVICES = {
    "exa": {"interval": 1.0, "daily": 45},
    "parallel": {"interval": 1.0, "daily": 60},
    "firecrawl": {"interval": 1.0, "daily": 30},
    "keenable": {"interval": 1.0, "daily": 60},
    "wikipedia": {"interval": 1.0, "daily": 500},
    "wikidata": {"interval": 1.0, "daily": 500},
    "arxiv": {"interval": 3.0, "daily": 300},      # arXiv asks for one request every three seconds
    "crossref": {"interval": 1.0, "daily": 500},
    "pubmed": {"interval": 1.0, "daily": 500},     # NCBI allows three a second without a key
    "github": {"interval": 6.0, "daily": 150},     # ten anonymous searches a minute, 60 calls an hour
    "hackernews": {"interval": 1.0, "daily": 500},
    "archive": {"interval": 1.0, "daily": 300},
}
LABELS = {"exa": "Exa", "parallel": "Parallel", "firecrawl": "Firecrawl", "keenable": "Keenable",
          "wikipedia": "Wikipedia", "wikidata": "Wikidata", "arxiv": "arXiv", "crossref": "Crossref",
          "pubmed": "PubMed", "github": "GitHub", "hackernews": "Hacker News", "archive": "the Internet Archive"}
FIRST_BACKOFF = 30.0
MAX_BACKOFF = 3600.0
HOST_INTERVAL = 2.0
MAX_CRAWL_DELAY = 30.0
HOST_REST_DEFAULT = 600.0


class Resting(Exception):
    """A service or site is resting; ``message`` says until when, in plain words."""

    def __init__(self, message, until):
        super().__init__(message)
        self.message = message
        self.until = until


def _local_day(now):
    return datetime.fromtimestamp(now).strftime("%Y-%m-%d")


def _next_local_midnight(now):
    moment = datetime.fromtimestamp(now)
    tomorrow = (moment + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return tomorrow.timestamp()


def _clock_text(until, now):
    moment = datetime.fromtimestamp(until)
    if _local_day(until) != _local_day(now):
        return "tomorrow"
    return moment.strftime("%H:%M")


def classify_failure(message):
    """'quota' for daily or credit limits, 'slow' for rate limits, None for anything else."""
    text = (message or "").lower()
    if any(m in text for m in ("quota", "daily limit", "per day", "credits", "monthly limit", "http 402",
                               "payment required", "usage limit", "free tier limit")):
        return "quota"
    if any(m in text for m in ("rate limit", "rate-limit", "ratelimit", "too many requests", "429",
                               "slow down", "throttl", "retry after", "try again later")):
        return "slow"
    return None


class ServiceLimits:
    def __init__(self, root, *, clock=time.time, sleep=time.sleep, services=None):
        self.root = Path(root)
        self.path = self.root / "services.json"
        self.clock, self.sleep = clock, sleep
        configured = dict(SERVICES)
        overrides = (load_settings(self.root).get("services") or {}) if services is None else services
        for name, values in overrides.items():
            if isinstance(values, dict):
                configured[name] = {**configured.get(name, {"interval": 1.0, "daily": 100}),
                                    **{k: float(v) for k, v in values.items() if k in ("interval", "daily")}}
        self.services = configured

    def _entry(self, data, name, now):
        entry = data.setdefault(name, {})
        day = _local_day(now)
        if entry.get("day") != day:
            entry.update(day=day, used=0)
            if entry.get("rest_reason") == "quota":
                entry.pop("rest_until", None)
                entry.pop("rest_reason", None)
        return entry

    def acquire(self, name, *, max_wait=20.0, count=1):
        """Reserve the next slot for ``name`` and wait for it. Raises Resting instead of waiting
        past ``max_wait``, when the service is resting, or when today's allowance is used."""
        config = self.services.get(name, {"interval": 1.0, "daily": 100})
        label = LABELS.get(name, name)
        refusal = None
        with locked_json(self.path, {}) as data:
            now = self.clock()
            entry = self._entry(data, name, now)
            until = float(entry.get("rest_until") or 0)
            slot = max(now, float(entry.get("next_at") or 0))
            if until > now:
                why = ("has used today's free allowance" if entry.get("rest_reason") == "quota"
                       else "asked Nollie to slow down")
                refusal = Resting(f"{label} {why} and is resting until {_clock_text(until, now)} "
                                  f"(rate limit kept by Nollie).", until)
            elif entry.get("used", 0) + count > config["daily"]:
                until = _next_local_midnight(now)
                entry.update(rest_until=until, rest_reason="quota")
                refusal = Resting(f"{label} has used today's free allowance and is resting until tomorrow "
                                  f"(quota exceeded, kept by Nollie).", until)
            elif slot - now > max_wait:
                refusal = Resting(f"{label} is busy with other bots' requests; try again shortly "
                                  f"(rate limit kept by Nollie).", slot)
            else:
                entry["next_at"] = slot + config["interval"] * count
                entry["used"] = entry.get("used", 0) + count
        if refusal is not None:
            raise refusal
        wait = slot - self.clock()
        if wait > 0:
            self.sleep(wait)

    def report(self, name, outcome, retry_after=None):
        """``ok`` clears back-off; ``slow`` doubles it (honouring Retry-After); ``quota`` rests
        the service until the next local day."""
        with locked_json(self.path, {}) as data:
            now = self.clock()
            entry = self._entry(data, name, now)
            if outcome == "ok":
                entry["backoff"] = 0
                return
            if outcome == "quota":
                entry.update(rest_until=_next_local_midnight(now), rest_reason="quota")
                return
            if outcome == "slow":
                level = int(entry.get("backoff") or 0) + 1
                pause = min(FIRST_BACKOFF * 2 ** (level - 1), MAX_BACKOFF)
                if retry_after:
                    pause = min(max(pause, float(retry_after)), MAX_BACKOFF)
                entry.update(backoff=level, rest_until=now + pause, rest_reason="slow")

    def status(self):
        data = read_json(self.path, {})
        now = self.clock()
        out = {}
        for name, config in self.services.items():
            entry = data.get(name, {})
            used = entry.get("used", 0) if entry.get("day") == _local_day(now) else 0
            until = float(entry.get("rest_until") or 0)
            out[name] = {"used_today": used, "daily_cap": int(config["daily"]),
                         "resting_until": datetime.fromtimestamp(until).isoformat(timespec="minutes")
                         if until > now else None}
        return out


class HostPacer:
    """Spacing between requests to one site, shared by every bot."""

    def __init__(self, root, *, clock=time.time, sleep=time.sleep, interval=HOST_INTERVAL):
        self.path = Path(root) / "hosts.json"
        self.clock, self.sleep, self.interval = clock, sleep, interval

    def wait_turn(self, host, *, crawl_delay=None, max_wait=20.0):
        spacing = self.interval
        if crawl_delay:
            spacing = max(spacing, min(float(crawl_delay), MAX_CRAWL_DELAY))
        refusal = None
        with locked_json(self.path, {}) as data:
            now = self.clock()
            for key in [k for k, v in data.items()
                        if max(v.get("next_at", 0), v.get("rest_until", 0)) < now - 3600]:
                data.pop(key, None)
            entry = data.setdefault(host, {})
            until = float(entry.get("rest_until") or 0)
            slot = max(now, float(entry.get("next_at") or 0))
            if until > now:
                refusal = Resting(f"This site asked bots to slow down. Nollie will wait until "
                                  f"{_clock_text(until, now)} before reading it again.", until)
            elif slot - now > max_wait:
                refusal = Resting("This site is busy with other reads from Nollie; try again in a minute.", slot)
            else:
                entry["next_at"] = slot + spacing
        if refusal is not None:
            raise refusal
        wait = slot - self.clock()
        if wait > 0:
            self.sleep(wait)
        return slot

    def rest(self, host, seconds=None):
        pause = min(max(float(seconds or HOST_REST_DEFAULT), 60.0), MAX_BACKOFF)
        with locked_json(self.path, {}) as data:
            entry = data.setdefault(host, {})
            entry["rest_until"] = max(float(entry.get("rest_until") or 0), self.clock() + pause)


def retry_after_seconds(value, now=None):
    """Retry-After as seconds, from either a number or an HTTP date."""
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        return float(value)
    try:
        from email.utils import parsedate_to_datetime
        moment = parsedate_to_datetime(value)
        return max(0.0, moment.timestamp() - (now or time.time()))
    except (TypeError, ValueError, IndexError):
        return None
