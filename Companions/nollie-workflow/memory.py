"""What a helper remembers, for the person to see and change: Hermes's own memory files.

Hermes keeps two lists in a bot's home, ``memories/USER.md`` (who the person is) and
``memories/MEMORY.md`` (the bot's own notes), each entry separated by a line holding only ``§``.
The agent writes them with its memory tool while holding an exclusive ``flock`` on the file's
``.lock`` neighbour, and so does this: every change takes the same lock, reads the file again,
changes exactly the entry the person saw, and replaces the file whole. So an entry Hermes adds
while the person is editing is kept, and an edit to an entry Hermes has just changed is refused
with the list as it is now, never written over it.

Turning memory off is Hermes's own setting (``memory.memory_enabled`` and
``memory.user_profile_enabled`` in the bot's config.yaml), saved through Hermes's config calls.
"""
from __future__ import annotations

import contextlib
import errno
import hashlib
import os
from pathlib import Path
import tempfile
import time

DELIMITER = "\n§\n"
FILES = {"user": "USER.md", "memory": "MEMORY.md"}
# Hermes's defaults (config_defaults.py), used when the bot's config sets no limit.
LIMITS = {"user": 1375, "memory": 2200}
LIMIT_KEYS = {"user": "user_char_limit", "memory": "memory_char_limit"}
MAX_FILE_BYTES = 256 * 1024
MAX_ENTRY_CHARS = 4000
LOCK_WAIT = 3.0


class Changed(Exception):
    """The entry the person was looking at is not in the file any more."""


class Refused(ValueError):
    """A change Hermes would not keep; the message is for the person."""


class Busy(Exception):
    """The file is locked for longer than a request should wait, or cannot be read right now."""


def parse(raw):
    """The entries of one file, in the order Hermes keeps them, stripped, empty ones and repeats dropped."""
    seen = []
    for part in raw.split(DELIMITER):
        entry = part.strip()
        if entry and entry not in seen:
            seen.append(entry)
    return seen


def entry_id(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def truthy(value, default=True):
    """Hermes's reading of a config switch: a bool, or words like "false" and "off"."""
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() not in {"false", "0", "no", "off", ""}


class HermesConfig:
    """Hermes's own calls for a bot's config, made with that bot's home in scope."""

    @staticmethod
    @contextlib.contextmanager
    def scope(home):
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override
        token = set_hermes_home_override(str(home))
        try:
            yield
        finally:
            reset_hermes_home_override(token)

    def section(self, home):
        from hermes_cli.config import read_raw_config
        with self.scope(home):
            raw = read_raw_config()
        section = raw.get("memory") if isinstance(raw, dict) else None
        return section if isinstance(section, dict) else {}

    def save_switch(self, home, on):
        from hermes_cli.config import save_config
        with self.scope(home):
            save_config({"memory": {"memory_enabled": bool(on), "user_profile_enabled": bool(on)}}, merge_existing=True)

    def scan(self, text):
        """Hermes's own check for words that would steer the agent, the one its memory tool runs."""
        try:
            from tools.threat_patterns import first_threat_message
        except ImportError:
            return None
        return first_threat_message(text, scope="strict")


class Memory:
    """One bot's two memory files, read and changed safely beside a running Hermes."""

    def __init__(self, home, config=None):
        self.home = Path(home)
        self.folder = self.home / "memories"
        self.config = config or HermesConfig()

    # Reading

    def _path(self, target):
        if target not in FILES:
            raise Refused("Choose about you or its notes.")
        return self.folder / FILES[target]

    def _read(self, path):
        """The file's text, "" when it is not there. A link, a huge file or broken text is never read."""
        for place in (self.home, self.folder, path):
            if place.is_symlink():
                raise Busy("This memory is a link, so it is left alone.")
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except FileNotFoundError:
            return ""
        except OSError:
            raise Busy("This memory can't be read right now.") from None
        with os.fdopen(fd, "rb") as handle:
            data = handle.read(MAX_FILE_BYTES + 1)
        if len(data) > MAX_FILE_BYTES:
            raise Busy("This memory is too large to show.")
        try:
            return data.decode("utf-8-sig")
        except UnicodeDecodeError:
            raise Busy("This memory can't be read right now.") from None

    def _section(self):
        try:
            return self.config.section(self.home)
        except Exception:
            return {}

    def view(self, bot):
        section = self._section()
        stores = {}
        for target in FILES:
            entries = parse(self._read(self._path(target)))
            stores[target] = {
                "entries": [{"id": entry_id(e), "text": e} for e in entries],
                "used": len(DELIMITER.join(entries)),
                "limit": self._limit(target, section),
            }
        on = truthy(section.get("memory_enabled")) or truthy(section.get("user_profile_enabled"))
        provider = section.get("provider") if isinstance(section.get("provider"), str) else ""
        return {"bot": bot, "on": on, "provider": provider.strip(), "stores": stores}

    @staticmethod
    def _limit(target, section):
        value = section.get(LIMIT_KEYS[target])
        try:
            return max(1, int(value)) if value is not None else LIMITS[target]
        except (TypeError, ValueError):
            return LIMITS[target]

    # Changing

    @contextlib.contextmanager
    def _locked(self, path):
        """Hermes's own lock for this file: an exclusive flock on ``<file>.lock``, never the file itself."""
        import fcntl
        self.folder.mkdir(mode=0o700, exist_ok=True)
        if self.folder.is_symlink():
            raise Busy("This memory is a link, so it is left alone.")
        lock = path.with_name(path.name + ".lock")
        fd = os.open(lock, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.fchmod(fd, 0o600)
            deadline = time.monotonic() + LOCK_WAIT
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as exc:
                    if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES) or time.monotonic() > deadline:
                        raise Busy("Your helper is saving to its memory. Try again in a moment.") from None
                    time.sleep(0.05)
            try:
                yield
            finally:
                with contextlib.suppress(OSError):
                    fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    def _write(self, path, entries):
        """The whole file at once: a reader sees the old list or the new one, never half."""
        mode = 0o600
        with contextlib.suppress(FileNotFoundError):
            mode = os.stat(path).st_mode & 0o777
        fd, temporary = tempfile.mkstemp(prefix=".mem_", dir=self.folder)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), mode)
                handle.write(DELIMITER.join(entries))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)

    def _checked(self, text):
        text = (text or "").strip() if isinstance(text, str) else ""
        if not text:
            raise Refused("Write something to remember.")
        if len(text) > MAX_ENTRY_CHARS or DELIMITER.strip() in text.splitlines():
            raise Refused("Keep it to one short note.")
        if self.config.scan(text):
            raise Refused("Your helper can't keep that. Try other words.")
        return text

    def _change(self, target, step):
        """Lock, read again, change, check the size, write. ``step`` returns the new list."""
        path = self._path(target)
        limit = self._limit(target, self._section())
        with self._locked(path):
            entries = parse(self._read(path))
            changed = step(list(entries))
            if changed == entries:
                return
            if len(DELIMITER.join(changed)) > limit and len(DELIMITER.join(changed)) > len(DELIMITER.join(entries)):
                raise Refused("Its memory is full. Forget something first.")
            self._write(path, changed)

    def add(self, target, text):
        text = self._checked(text)

        def step(entries):
            return entries if text in entries else entries + [text]
        self._change(target, step)

    def edit(self, target, old, text):
        text = self._checked(text)

        def step(entries):
            if old not in entries:
                raise Changed(old)
            if text in entries and text != old:
                return [e for e in entries if e != old]
            return [text if e == old else e for e in entries]
        self._change(target, step)

    def forget(self, target, old):
        """Gone already counts as done: the person wanted it gone."""
        self._change(target, lambda entries: [e for e in entries if e != old])

    def set_on(self, on):
        self.config.save_switch(self.home, on)
