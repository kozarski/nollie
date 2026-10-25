"""Loads the add-on as a package and runs small local HTTP servers. No real network."""
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]


def load():
    name = "nollie_reader_under_test"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, ROOT / "__init__.py",
                                                      submodule_search_locations=[str(ROOT)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    import importlib as _il
    return {part: _il.import_module(f"{name}.{part}") for part in
            ("state", "netsafe", "rules", "extract", "limits", "cache", "reader", "search_limits", "references")}


class Site:
    """A local server. ``routes`` maps a path to (status, headers, body) or a callable."""

    def __init__(self, routes=None):
        self.routes = dict(routes or {})
        self.hits = []
        site = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                site.hits.append((self.path, dict(self.headers)))
                route = site.routes.get(self.path)
                if route is None:
                    route = site.routes.get(self.path.split("?", 1)[0], (404, {}, b"not here"))
                if callable(route):
                    route = route(self)
                    if route is None:  # the route wrote its own reply
                        return
                status, headers, body = route
                body = body.encode() if isinstance(body, str) else body
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                if "Content-Length" not in headers:
                    self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def paths(self):
        return [p for p, _ in self.hits]


def test_network(netsafe, names):
    """A resolver for made-up public names that all point at the local server, and an address
    rule that allows only 127.0.0.1 on top of the real one. Everything else keeps the real rules."""
    def resolver(host, port):
        if host in names:
            return [names[host]]
        raise OSError("no such name in the test network")

    def allowed(address):
        return address == "127.0.0.1" or netsafe.address_allowed(address)

    return resolver, allowed
