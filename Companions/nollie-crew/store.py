"""Small file helpers: private atomic JSON, a file lock and the YAML Hermes reads."""
import contextlib
import json
import os
from pathlib import Path
import tempfile

try:  # Inside Hermes: the same YAML layer Hermes itself uses.
    import hermes_yaml as _yaml
except ImportError:  # pragma: no cover - depends on the interpreter
    try:
        import yaml as _yaml
    except ImportError:
        _yaml = None


def _write_bytes(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise ValueError("refusing a linked destination")
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def write_json(path, value):
    _write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode())


def read_json(path, default=None):
    path = Path(path)
    if not path.exists():
        return default
    if path.is_symlink():
        raise ValueError("refusing a linked file")
    return json.loads(path.read_text(encoding="utf-8"))


def write_text(path, text):
    _write_bytes(path, text.encode("utf-8"))


def read_yaml(path):
    path = Path(path)
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        return {}
    # JSON is valid YAML, so a home written without a YAML library still reads back.
    value = _yaml.safe_load(text) if _yaml is not None else json.loads(text)
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError("config is not a mapping")
    return value


def write_yaml(path, value):
    if _yaml is not None:
        text = _yaml.safe_dump(value, sort_keys=False, allow_unicode=True)
    else:
        text = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    _write_bytes(path, text.encode("utf-8"))


@contextlib.contextmanager
def file_lock(path):
    import fcntl
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a") as handle:
        os.chmod(path, 0o600)
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
