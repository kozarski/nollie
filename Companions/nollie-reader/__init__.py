"""Nollie's polite reader for every bot except the private one."""
import re

_PRIVATE = {"private", "moss"}


def register(ctx):
    profile = str(getattr(ctx, "profile_name", "") or "")
    if set(re.split(r"[^a-z0-9]+", profile.lower())) & _PRIVATE:
        return
    from .hermes_glue import register as register_reader
    register_reader(ctx)
