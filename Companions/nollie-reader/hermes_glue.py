"""Connects the reader to Hermes: a web_extract backend, limits on the keyless search ring,
the reference_lookup tool and skill, and a guard that keeps the browser away from a site that
just asked for a person. Imported only inside Hermes."""
from __future__ import annotations

import json
import logging
from pathlib import Path

from .reader import Reader, handoff_for, READER
from .references import References, SCHEMA as REFERENCE_SCHEMA, DESCRIPTION as REFERENCE_DESCRIPTION
from .state import load_settings, shared_root

logger = logging.getLogger(__name__)
SKILL = Path(__file__).with_name("skills") / "reference-sources" / "SKILL.md"
_GUARDED_TOOLS = ("browser_navigate",)


def make_provider(reader_factory):
    from agent.web_search_provider import WebSearchProvider

    class NollieReaderProvider(WebSearchProvider):
        """Reads pages on this Mac. Search stays with the configured search backend."""

        @property
        def name(self):
            return READER

        @property
        def display_name(self):
            return "Nollie reader"

        def is_available(self):
            return True

        def supports_search(self):
            return False

        def supports_extract(self):
            return True

        def extract(self, urls, **kwargs):
            return reader_factory().read_many(list(urls), kwargs.get("format") or "markdown")

        def get_setup_schema(self):
            return {"name": "Nollie reader", "badge": "free · on this Mac",
                    "tag": "Reads pages politely on this Mac: robots.txt, AI-use signals, no workarounds.",
                    "env_vars": []}

    return NollieReaderProvider()


def guard(root):
    def on_pre_tool_call(tool_name="", args=None, **_):
        if tool_name not in _GUARDED_TOOLS or not isinstance(args, dict):
            return None
        if load_settings(root).get("handoff_guard", True) is False:
            return None
        url = args.get("url")
        if isinstance(url, str) and handoff_for(root, url):
            return {"action": "block",
                    "message": "This site asked for a person when Nollie tried to read it, so the browser "
                               "will not try it either. Share the link and ask a person to open it."}
        return None
    return on_pre_tool_call


def register(ctx):
    root = shared_root()
    state = {"reader": None}

    def reader():
        if state["reader"] is None:
            state["reader"] = Reader(root)
        return state["reader"]

    ctx.register_web_search_provider(make_provider(reader))

    references = References(root)

    def lookup(args, **_):
        args = args if isinstance(args, dict) else {}
        result = references.lookup(args.get("source", ""), args.get("query", ""), args.get("id", ""),
                                   args.get("limit", 5), args.get("language", "en"))
        return json.dumps(result, ensure_ascii=False)

    ctx.register_tool(name="reference_lookup", toolset="web", schema=REFERENCE_SCHEMA, handler=lookup,
                      description=REFERENCE_DESCRIPTION)
    if SKILL.is_file():
        ctx.register_skill("reference-sources", SKILL,
                           description="Free official reference sources and how to use them politely.")
    ctx.register_hook("pre_tool_call", guard(root))

    try:
        from plugins.web import keyless_mcp
        from . import search_limits
        limited = search_limits.install(keyless_mcp, root)
        ctx.on_unload(search_limits.uninstall)
        logger.info("Nollie search limits on: %s", ", ".join(limited))
    except Exception as error:
        logger.warning("Nollie search limits could not start: %s", error)
