"""Uses Hermes's supported auth provider registration and native PKCE flow."""
import importlib.util
import sys
from pathlib import Path


def register(ctx):
    from hermes_constants import get_process_hermes_home
    from hermes_cli.plugins_cmd import _get_enabled_set, _get_disabled_set

    name = "nollie_pairing_provider"
    module = sys.modules.get(name)
    if module is None:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("provider.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    enabled = lambda: "nollie-pairing" in _get_enabled_set() and "nollie-pairing" not in _get_disabled_set()
    provider = module.PairingProvider(Path(get_process_hermes_home()) / "nollie-pairing", enabled=enabled)
    ctx.register_dashboard_auth_provider(provider)
