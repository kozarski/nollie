"""Public-internet-only HTTP for the reader. Standard library only.

Every request is checked twice: the URL (scheme, no credentials, no internal names) and every
address the name resolves to. The connection then goes to the address that was checked, so a
second DNS answer cannot swap in a private one. Redirects are never followed here; the caller
checks each new location the same way. Proxies are never used.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import http.client
import ipaddress
import socket
import ssl
import time
from urllib.parse import urlsplit, quote
import zlib

USER_AGENT = "Nollie/0.1 (+https://nollie.app/bot)"
AGENT_TOKEN = "nollie"

_BLOCKED_NAMES = frozenset({
    "localhost", "metadata", "metadata.google.internal", "metadata.goog", "instance-data",
    "instance-data.ec2.internal", "kubernetes.default", "kubernetes.default.svc",
})
_BLOCKED_SUFFIXES = (".localhost", ".local", ".internal", ".home.arpa", ".lan", ".intranet", ".corp",
                     ".localdomain", ".in-addr.arpa", ".ip6.arpa")
_NAT64 = ipaddress.ip_network("64:ff9b::/96")
_NAT64_LOCAL = ipaddress.ip_network("64:ff9b:1::/48")


class Refused(Exception):
    """The reader will not contact this address. ``reason`` is safe to show."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _embedded(ip):
    """IPv4 addresses hidden inside IPv6 wrappers are judged as themselves."""
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return ip.ipv4_mapped
        if ip.sixtofour is not None:
            return ip.sixtofour
        if ip.teredo is not None:
            return ip.teredo[1]
        if ip in _NAT64:
            return ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF)
    return ip


def address_allowed(ip):
    """Only globally routable unicast addresses. Private, loopback, link-local (and so cloud
    metadata at 169.254.169.254), shared CGNAT space (Tailscale), reserved and multicast are out."""
    if isinstance(ip, str):
        try:
            ip = ipaddress.ip_address(ip.split("%", 1)[0])
        except ValueError:
            return False
    if isinstance(ip, ipaddress.IPv6Address) and (ip.scope_id or ip in _NAT64_LOCAL):
        return False
    inner = _embedded(ip)
    for candidate in {ip, inner}:
        if not candidate.is_global or candidate.is_multicast or candidate.is_unspecified:
            return False
    return True


def system_resolver(host, port):
    infos = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
    return [info[4][0] for info in infos]


@dataclass
class Target:
    url: str
    scheme: str
    host: str
    port: int
    path: str  # path plus query, what goes on the request line

    @property
    def origin(self):
        default = 443 if self.scheme == "https" else 80
        suffix = "" if self.port == default else f":{self.port}"
        host = f"[{self.host}]" if ":" in self.host else self.host
        return f"{self.scheme}://{host}{suffix}"


def normalize(url):
    """Parse and normalise a URL, refusing anything that is not a plain public http(s) address."""
    if not isinstance(url, str) or not url.strip():
        raise Refused("That is not a web address.")
    try:
        parts = urlsplit(url.strip())
        port = parts.port
    except ValueError:
        raise Refused("That web address could not be read.")
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https"):
        raise Refused("Nollie only reads http and https pages.")
    if parts.username is not None or parts.password is not None:
        raise Refused("Nollie does not send passwords inside web addresses.")
    host = (parts.hostname or "").rstrip(".").lower()
    if not host:
        raise Refused("That web address has no site name.")
    try:
        host = host.encode("idna").decode("ascii") if not host.isascii() else host
    except UnicodeError:
        raise Refused("That site name could not be read.")
    literal = None
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        pass
    if literal is None:
        if host in _BLOCKED_NAMES or host.endswith(_BLOCKED_SUFFIXES) or "." not in host:
            raise Refused("Nollie only reads public websites, not local or internal ones.")
    elif not address_allowed(literal):
        raise Refused("Nollie only reads public websites, not private or internal addresses.")
    port = port or (443 if scheme == "https" else 80)
    path = quote(parts.path or "/", safe="/%:@!$&'()*+,;=~-._")
    if parts.query:
        path += "?" + quote(parts.query, safe="/%:@!$&'()*+,;=~-._?")
    netloc_host = f"[{host}]" if ":" in host else host
    default = 443 if scheme == "https" else 80
    netloc = netloc_host if port == default else f"{netloc_host}:{port}"
    return Target(f"{scheme}://{netloc}{path}", scheme, host, port, path)


def resolve_public(target, resolver=system_resolver, allowed=address_allowed):
    """Every answer must be public; one private answer refuses the whole name."""
    try:
        literal = ipaddress.ip_address(target.host)
    except ValueError:
        literal = None
    if literal is not None:
        addresses = [str(literal)]
    else:
        try:
            addresses = list(dict.fromkeys(resolver(target.host, target.port)))
        except (OSError, UnicodeError):
            raise LookupError("The site name could not be found.")
    if not addresses:
        raise LookupError("The site name could not be found.")
    if not all(allowed(a) for a in addresses):
        raise Refused("That site points to a private or internal address, so Nollie stopped.")
    return addresses


class _PinnedHTTP(http.client.HTTPConnection):
    def __init__(self, host, port, address, timeout):
        super().__init__(host, port, timeout=timeout)
        self._address = address

    def connect(self):
        self.sock = socket.create_connection((self._address, self.port), self.timeout)


class _PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, port, address, timeout):
        super().__init__(host, port, timeout=timeout)
        self._address = address
        self._tls = ssl.create_default_context()

    def connect(self):
        sock = socket.create_connection((self._address, self.port), self.timeout)
        self.sock = self._tls.wrap_socket(sock, server_hostname=self.host)


@dataclass
class Response:
    url: str
    status: int
    headers: dict = field(default_factory=dict)  # lower-case name -> list of values
    body: bytes = b""
    truncated: bool = False

    def header(self, name, default=""):
        values = self.headers.get(name.lower())
        return values[0] if values else default

    def all(self, name):
        return self.headers.get(name.lower(), [])


class TooLarge(Exception):
    pass


class _TooSlow(Exception):
    pass


def _decode_body(raw, encoding, limit):
    encoding = (encoding or "").strip().lower()
    if encoding in ("", "identity"):
        return raw
    if encoding in ("gzip", "x-gzip", "deflate"):
        wbits = 47 if encoding != "deflate" else zlib.MAX_WBITS
        decoder = zlib.decompressobj(wbits)
        try:
            out = decoder.decompress(raw, limit + 1)
        except zlib.error:
            if encoding == "deflate":
                decoder = zlib.decompressobj(-zlib.MAX_WBITS)
                out = decoder.decompress(raw, limit + 1)
            else:
                raise
        if len(out) > limit:
            raise TooLarge()
        return out
    raise ValueError("unsupported content encoding")


def _read_body(reply, max_bytes, finish_by):
    """Read at most ``max_bytes + 1`` bytes, giving up on a site that drips data forever."""
    chunks, size = [], 0
    while size <= max_bytes:
        if time.monotonic() > finish_by:
            raise _TooSlow()
        chunk = reply.read1(min(65536, max_bytes + 1 - size))
        if not chunk:
            break
        chunks.append(chunk)
        size += len(chunk)
    return b"".join(chunks)


def fetch_once(target, *, headers=None, timeout=15.0, max_bytes=8_000_000, method="GET",
               resolver=system_resolver, allowed=address_allowed, total_timeout=60.0):
    """One request to an already-normalised target. Never follows redirects."""
    finish_by = time.monotonic() + total_timeout
    addresses = resolve_public(target, resolver, allowed)
    sent = {"User-Agent": USER_AGENT, "Accept-Encoding": "gzip, deflate", "Connection": "close"}
    sent.update(headers or {})
    last_error = None
    for address in addresses[:3]:
        cls = _PinnedHTTPS if target.scheme == "https" else _PinnedHTTP
        connection = cls(target.host, target.port, address, timeout)
        try:
            connection.request(method, target.path, headers=sent)
            reply = connection.getresponse()
            collected = {}
            for name, value in reply.getheaders():
                collected.setdefault(name.lower(), []).append(value)
            raw = _read_body(reply, max_bytes, finish_by) if method != "HEAD" else b""
            truncated = len(raw) > max_bytes
            raw = raw[:max_bytes]
            encoding = (collected.get("content-encoding") or [""])[0]
            try:
                body = _decode_body(raw, encoding, max_bytes)
            except TooLarge:
                body, truncated = b"", True
            except (zlib.error, ValueError):
                body = raw if not encoding else b""
            return Response(target.url, reply.status, collected, body, truncated)
        except _TooSlow:
            raise ConnectionError("The site was too slow to send the page.")
        except (OSError, http.client.HTTPException) as error:
            last_error = error
        finally:
            connection.close()
    raise ConnectionError(f"The site did not answer ({type(last_error).__name__}).")
