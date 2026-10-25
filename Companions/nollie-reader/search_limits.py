"""Shared polite limits around Hermes's keyless search ring (Exa, Parallel, Firecrawl, Keenable).

Hermes looks each vendor's keyless function up by name at call time
(``plugins.web.keyless_mcp.<vendor>_search_keyless``), so wrapping those names covers every
route into a free tier: the pinned backend, the round-robin ring, its failover and the
one-shot rescue. A resting or capped service answers with a rate-limit-shaped error, which
is exactly what makes the ring move on to the next service. Keyed (paid) calls are untouched.
"""
from __future__ import annotations

import functools
import logging
import threading

from .limits import Resting, ServiceLimits, classify_failure

logger = logging.getLogger(__name__)
RING = ("exa", "parallel", "firecrawl", "keenable")
_MARK = "_nollie_limited"
_lock = threading.Lock()
_installed = {"count": 0, "originals": {}}


def _search_wrapper(vendor, original, limits):
    @functools.wraps(original)
    def limited(query, limit=5):
        try:
            limits.acquire(vendor)
        except Resting as resting:
            return {"success": False, "error": f"Keyless {vendor} search paused: {resting.message}"}
        result = original(query, limit)
        error = "" if not isinstance(result, dict) or result.get("success") else str(result.get("error", ""))
        limits.report(vendor, (classify_failure(error) or "ok") if error else "ok")
        return result

    setattr(limited, _MARK, True)
    return limited


def _extract_wrapper(vendor, original, limits):
    @functools.wraps(original)
    def limited(urls):
        urls = list(urls)
        try:
            limits.acquire(vendor, count=max(1, len(urls)))
        except Resting as resting:
            return [{"url": u, "title": "", "content": "", "error": f"Keyless {vendor} extract paused: {resting.message}"}
                    for u in urls]
        results = original(urls)
        errors = [str(r.get("error") or "") for r in results or [] if isinstance(r, dict)]
        kinds = {classify_failure(e) for e in errors if e}
        limits.report(vendor, "quota" if "quota" in kinds else "slow" if "slow" in kinds else "ok")
        return results

    setattr(limited, _MARK, True)
    return limited


def install(module, root, *, limits=None):
    """Wrap the ring's vendor functions once per process. Returns the names that are limited."""
    limits = limits or ServiceLimits(root)
    wrapped = []
    with _lock:
        for vendor in RING:
            for kind, factory in (("search", _search_wrapper), ("extract", _extract_wrapper)):
                name = f"{vendor}_{kind}_keyless"
                current = getattr(module, name, None)
                if current is None:
                    continue
                if not getattr(current, _MARK, False):
                    _installed["originals"][(id(module), name)] = (module, current)
                    setattr(module, name, factory(vendor, current, limits))
                wrapped.append(name)
        _installed["count"] += 1
    if not wrapped:
        logger.warning("Nollie search limits found no keyless vendor functions; limits are off.")
    return wrapped


def uninstall():
    """Undo ``install`` once the last loader in this process has gone."""
    with _lock:
        _installed["count"] = max(0, _installed["count"] - 1)
        if _installed["count"]:
            return
        for (_, name), (module, original) in list(_installed["originals"].items()):
            if getattr(getattr(module, name, None), _MARK, False):
                setattr(module, name, original)
        _installed["originals"].clear()
