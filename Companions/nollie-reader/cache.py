"""One-hour shared cache of what the reader found, refusals included, so a site is not asked
twice in an hour by different bots. Pages marked noarchive are never stored."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import time

from .state import atomic_write, ensure_dir, read_json

TTL = 3600.0
_PRUNE_EVERY = 600.0


class Cache:
    def __init__(self, root, *, ttl=TTL, clock=time.time):
        self.dir = Path(root) / "cache"
        self.ttl, self.clock = ttl, clock

    def _file(self, kind, key):
        digest = hashlib.sha256(json.dumps([kind, key], separators=(",", ":")).encode()).hexdigest()
        return self.dir / f"{digest}.json"

    def get(self, kind, key):
        record = read_json(self._file(kind, key), {})
        stored = record.get("stored_at")
        if not isinstance(stored, (int, float)) or self.clock() - stored > record.get("ttl", self.ttl):
            return None
        return record.get("value")

    def put(self, kind, key, value, ttl=None):
        ensure_dir(self.dir)
        atomic_write(self._file(kind, key), {"stored_at": self.clock(), "ttl": ttl or self.ttl, "value": value})
        self._prune()

    def _prune(self):
        marker = self.dir / ".pruned"
        now = self.clock()
        if now - read_json(marker, {}).get("at", 0) < _PRUNE_EVERY:
            return
        atomic_write(marker, {"at": now})
        for path in self.dir.glob("*.json"):
            record = read_json(path, {})
            stored = record.get("stored_at")
            if not isinstance(stored, (int, float)) or now - stored > record.get("ttl", self.ttl):
                try:
                    path.unlink()
                except OSError:
                    continue

    def clear(self):
        count = 0
        for path in self.dir.glob("*.json"):
            try:
                os.unlink(path)
                count += 1
            except OSError:
                pass
        return count
