"""The cards the add-on has posted into Nollie's main chat, bounded to 30 days and 8 MB."""
from __future__ import annotations

import json
from pathlib import Path
import time

from .workflow_core import atomic_write, file_lock

FILE_NAME = "posts.json"
LOCK_NAME = "posts.lock"
KEEP_SECONDS = 30 * 86400
MAX_POSTS = 400
MAX_BYTES = 8_000_000
# A store a writer finds over its size (from an older build) is still read once to be cut back.
REPAIR_BYTES = 4 * MAX_BYTES
MAX_POST_BYTES = 1_000_000
KINDS = frozenset(("night_shift", "rehearsal"))


def valid(post):
    return (isinstance(post, dict) and isinstance(post.get("id"), str) and post.get("kind") in KINDS
            and type(post.get("at")) is int)


class PostStore:
    def __init__(self, root, now=time.time):
        self.root, self.now = Path(root), now

    def _read(self, limit=None):
        path = self.root / FILE_NAME
        try:
            if path.is_symlink():
                raise ValueError("linked post store")
            if path.stat().st_size > (limit or MAX_BYTES):
                raise ValueError("oversized post store")
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return []
        except UnicodeDecodeError:
            raise ValueError("unreadable post store") from None
        posts = document.get("posts") if isinstance(document, dict) and document.get("version") == 1 else None
        if not isinstance(posts, list):
            raise ValueError("invalid post store")
        return [post for post in posts if valid(post)]

    def _bounded(self, posts):
        oldest = int(self.now()) - KEEP_SECONDS
        posts = sorted((p for p in posts if p["at"] >= oldest), key=lambda p: (p["at"], p["id"]))
        return posts[-MAX_POSTS:]

    def _write(self, posts):
        """Save the newest posts that fit in the size bound; the oldest fall off first."""
        posts = self._bounded(posts)
        sizes = [len(json.dumps(p, ensure_ascii=False, separators=(",", ":")).encode()) + 1 for p in posts]
        total = sum(sizes) + 32
        while posts and total > MAX_BYTES:
            total -= sizes.pop(0)
            posts.pop(0)
        atomic_write(self.root / FILE_NAME, {"version": 1, "posts": posts})
        return posts

    def all(self):
        return self._bounded(self._read())

    def get(self, post_id):
        return next((p for p in self.all() if p["id"] == post_id), None)

    def put(self, post):
        """Add a post, or replace the one with the same id. Old posts fall off."""
        if not valid(post):
            raise ValueError("invalid post")
        if len(json.dumps(post, ensure_ascii=False, separators=(",", ":")).encode()) > MAX_POST_BYTES:
            raise ValueError("oversized post")
        with file_lock(self.root / LOCK_NAME):
            posts = [p for p in self._read(REPAIR_BYTES) if p["id"] != post["id"]] + [post]
            self._write(posts)
        return post

    def update(self, post_id, **changes):
        with file_lock(self.root / LOCK_NAME):
            posts = self._read(REPAIR_BYTES)
            found = next((p for p in posts if p["id"] == post_id), None)
            if found is None:
                return None
            found.update(changes)
            self._write(posts)
            return found

    def since(self, since, limit):
        """The newest ``limit`` posts at or after ``since``, oldest first."""
        posts = [p for p in self.all() if p["at"] >= since]
        return posts[-limit:] if limit > 0 else []
