"""Shared helpers for Tools/pins.json: read the pins, fetch and check pinned downloads.

Standard library only. Downloads are checked by size and SHA-256 before anything reads them,
and archives are unpacked only after every member has been checked for a safe path.
"""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / "Tools" / "pins.json"
OVERLAY = ROOT / "Services" / "Runtime" / "HermesOverlay"
# The hosts a pinned download may come from (the app's own list plus the reference-only ones).
HOSTS = {"github.com", "codeload.github.com", "release-assets.githubusercontent.com",
         "objects.githubusercontent.com", "static.rust-lang.org"}


def load(path=PINS):
    data = json.loads(Path(path).read_text())
    if data.get("schema") != 1 or not isinstance(data.get("components"), list):
        raise ValueError("Tools/pins.json has an unknown layout")
    return data


def component(pins, identifier):
    for item in pins["components"]:
        if item["id"] == identifier:
            return item
    raise KeyError(identifier)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


class _Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        host = urllib.parse.urlsplit(newurl).hostname
        if not newurl.startswith("https://") or host not in HOSTS:
            raise ValueError(f"redirected outside the allowed hosts: {host}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(artifact, destination, opener=None):
    """Download one pinned artifact to destination, or reuse a copy already there; both are checked."""
    destination = Path(destination)
    url = artifact["url"]
    if not url.startswith("https://") or urllib.parse.urlsplit(url).hostname not in HOSTS:
        raise ValueError(f"not an allowed download: {url}")
    expected = artifact.get("bytes")
    if destination.exists() and _matches(destination, artifact):
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    opener = opener or urllib.request.build_opener(_Redirects())
    with opener.open(url, timeout=60) as response, open(partial, "wb") as out:
        written = 0
        for block in iter(lambda: response.read(1 << 20), b""):
            written += len(block)
            if expected is not None and written > expected:
                raise ValueError(f"{url} is larger than the pinned {expected} bytes")
            out.write(block)
    if not _matches(partial, artifact):
        partial.unlink()
        raise ValueError(f"{url} does not match its pinned size and SHA-256")
    partial.replace(destination)
    return destination


def _matches(path, artifact):
    expected = artifact.get("bytes")
    return (expected is None or path.stat().st_size == expected) and sha256_file(path) == artifact["sha256"]


def safe_extract(archive, destination, strip=1):
    """Unpack a checked .tar.gz with its top folder removed. Links and odd paths are refused."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        tops = set()
        for member in members:
            parts = Path(member.name).parts
            if (member.name.startswith("/") or ".." in parts or "\\" in member.name
                    or not (member.isfile() or member.isdir())):
                raise ValueError(f"unsafe archive member: {member.name}")
            tops.add(parts[0] if parts else "")
        if len(tops) != 1:
            raise ValueError("the archive has more than one top folder")
        for member in members:
            parts = Path(member.name).parts[strip:]
            if not parts:
                continue
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as source, open(target, "wb") as out:
                shutil.copyfileobj(source, out)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    return destination


def overlay_manifest(root=OVERLAY):
    return json.loads((Path(root) / "overlay.json").read_text())


def overlay_digest(root=OVERLAY):
    return sha256_bytes((Path(root) / "overlay.json").read_bytes())

