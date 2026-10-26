"""Papertrail for the main bot and the bots chosen for it, the Night shift recorder, saved sign-ins and the Mac's
Calendar, Reminders and Contacts for every bot that is not private, and Board follow-through for the main bot only. Ask first, and the picture pause that
keeps a typed password out of screenshots, load in every bot that is not private. Nothing loads for a private bot.
"""


def register(ctx):
    from pathlib import Path
    from hermes_cli.profiles import get_profile_dir
    profile = str(getattr(ctx, "profile_name", "") or "")
    home = Path(get_profile_dir("default")).resolve()
    # First, so a call is held or refused before anything else looks at it.
    _register_ask_first(ctx, profile, home)
    try:
        from . import private_bots
        if private_bots.excluded(profile, private_bots.names(home)):
            return
    except Exception:
        return
    _register_papertrail(ctx, profile, home)
    if profile == "default":
        from .service import start
        if (home / "nollie-workflow" / "state.json").is_file():
            from .followup_tools import register as register_followups
            register_followups(ctx, home)
            start(home, ctx)
    _register_night_shift(ctx, profile, home)
    _register_sign_ins(ctx, profile, home)
    _register_apple_data(ctx, profile, home)


def _register_papertrail(ctx, profile, default_home):
    import logging
    try:
        from pathlib import Path
        if profile != "default" and (Path(__file__).parent / "recorder-only").exists():
            return  # The installer copied the add-on here for the Night shift recorder only.
        from hermes_constants import get_hermes_home
        from .private_bots import Watch
        bot_home = Path(get_hermes_home()).resolve()
        # Asked again before every line, so a bot marked Private later stops recording at once.
        is_private = Watch(default_home, profile, bot_home.name)
        try:
            if is_private():
                return
        except (OSError, ValueError):
            return  # A damaged Private list keeps every bot unrecorded until it is repaired.
        from .papertrail import HOOKS, Recorder
        recorder = Recorder(bot_home, is_private=is_private)
        for name in HOOKS:
            ctx.register_hook(name, getattr(recorder, name))
    except Exception as exc:
        logging.getLogger("nollie-workflow").warning("Papertrail did not start: %s", type(exc).__name__)


def _register_night_shift(ctx, profile, default_home):
    import logging
    try:
        from . import private_bots
        from .recorder import register as register_recorder
        try:
            private = private_bots.names(default_home) | private_bots.carried_over_names()
        except (OSError, ValueError):
            return  # A damaged Private list: no recorder anywhere until it is repaired.
        if not profile or private_bots.excluded(profile, private):
            return
        register_recorder(ctx, default_home, profile)
    except Exception as exc:
        logging.getLogger("nollie-workflow").warning("The Night shift recorder did not start: %s", type(exc).__name__)


def _register_sign_ins(ctx, profile, default_home):
    """request_sign_in, in the nollie_sign_in toolset. The Private list is checked again on every call."""
    import logging
    try:
        from pathlib import Path
        from hermes_constants import get_hermes_home
        from . import private_bots
        from .sign_ins import register as register_sign_ins
        try:
            private = private_bots.names(default_home) | private_bots.carried_over_names()
        except (OSError, ValueError):
            return  # A damaged Private list: no sign-ins anywhere until it is repaired.
        if not profile or private_bots.excluded(profile, private):
            return
        watch = private_bots.Watch(default_home, profile, Path(get_hermes_home()).resolve().name)
        register_sign_ins(ctx, default_home, profile, watch)
    except Exception as exc:
        logging.getLogger("nollie-workflow").warning("Saved sign-ins did not start: %s", type(exc).__name__)


def _register_apple_data(ctx, profile, default_home):
    """Calendar, Reminders and Contacts, each in its own toolset and shown only while its switch is on. The
    Private list is checked again on every call."""
    import logging
    try:
        from pathlib import Path
        from . import private_bots
        try:
            private = private_bots.names(default_home) | private_bots.carried_over_names()
        except (OSError, ValueError):
            return  # A damaged Private list: none of it anywhere until it is repaired.
        if not profile or private_bots.excluded(profile, private):
            return
        from hermes_constants import get_hermes_home
        from .apple_data import register as register_apple_data
        watch = private_bots.Watch(default_home, profile, Path(get_hermes_home()).resolve().name)
        register_apple_data(ctx, default_home, profile, watch)
    except Exception as exc:
        logging.getLogger("nollie-workflow").warning("Calendar, Reminders and Contacts did not start: %s",
                                                     type(exc).__name__)


def _register_ask_first(ctx, profile, default_home):
    """Ask first and the picture pause: two pre_tool_call hooks. If they can't load, the bot's computer and
    risky tools are refused outright instead of running unguarded."""
    import logging
    from pathlib import Path
    bot_home = Path(default_home) if profile == "default" else Path(default_home) / "profiles" / profile
    is_private = None
    try:
        from . import private_bots
        try:
            private = private_bots.names(default_home) | private_bots.carried_over_names()
        except (OSError, ValueError):
            # A damaged Private list: nothing reads this bot's work, but its risky calls stay refused. The
            # bots that are always private (Moss) get nothing at all.
            if profile and not private_bots.excluded(profile, private_bots.carried_over_names()):
                ctx.register_hook("pre_tool_call", _refuse_unguarded)
            return
        if not profile or private_bots.excluded(profile, private):
            return
        is_private = private_bots.Watch(default_home, profile)
        from .ask_first import AskFirst, hermes_bypassed, hermes_unattended
        from .receipts import hermes_redactor
        from .screen_text import HermesScreen, Memory, capture_space, owned_space
        from .sign_ins import RECORDINGS, PicturePause, typing_now
        pause = PicturePause(default_home)
        ctx.register_hook("pre_tool_call", pause.hook)
        # A call that passed the pause but finished once a fill had begun gives back no picture.
        ctx.register_hook("transform_tool_result", pause.result)
        ctx.register_hook("post_tool_call", RECORDINGS.post_tool_call)

        def capture(sandbox):
            # Ask first never looks while a saved sign-in may be on screen: it holds the call instead. A
            # picture taken while a fill began is thrown away unread.
            if typing_now(default_home):
                return None
            image = capture_space(sandbox)
            return None if typing_now(default_home) else image
        memory = Memory()
        screen = HermesScreen(memory, capture=capture, default_space=lambda: owned_space(default_home, profile))
        rule = AskFirst(unattended=hermes_unattended(ctx), bypassed=hermes_bypassed, screen=screen,
                        redactor=hermes_redactor())
        ctx.register_hook("pre_tool_call", _while_ask_first_on(rule.hook, bot_home, is_private))
        ctx.register_hook("post_tool_call", memory.post_tool_call)
    except Exception as exc:
        logging.getLogger("nollie-workflow").warning("Ask first did not start: %s", type(exc).__name__)
        ctx.register_hook("pre_tool_call", _while_ask_first_on(_refuse_unguarded, bot_home, is_private))


def _while_ask_first_on(hook, home, is_private=None):
    """A running bot follows config changes too, before Hermes reloads its add-ons."""
    from functools import wraps
    import json

    @wraps(hook)
    def checked(*args, **kwargs):
        try:
            if is_private is not None and is_private():
                return None
            config = home / "config.yaml"
            if config.is_symlink():
                raise ValueError("linked bot config")
            text = config.read_text()
            try:
                document = json.loads(text)
            except ValueError:
                try:
                    import hermes_yaml as yaml
                except ImportError:
                    import yaml
                document = yaml.safe_load(text)
            if not isinstance(document, dict):
                raise ValueError("invalid bot config")
            plugins = document.get("plugins", {})
            if not isinstance(plugins, dict):
                raise ValueError("invalid add-on settings")
            enabled, disabled = plugins.get("enabled", []), plugins.get("disabled", [])
            if not all(isinstance(names, list) and all(isinstance(name, str) for name in names)
                       for names in (enabled, disabled)):
                raise ValueError("invalid add-on lists")
            matches = lambda names: any(name.rsplit("/", 1)[-1] == "nollie-workflow" for name in names)
            if matches(disabled) or not matches(enabled):
                return None
        except Exception:
            return _refuse_unguarded(*args, **kwargs)
        return hook(*args, **kwargs)

    return checked


# Calls that only look things up: the stand-in lets them through even if the rules themselves can't load.
_LOOKS = frozenset(("web_search", "web_extract", "read_file", "search_files", "skill_view", "skills_list",
                    "session_search", "memory", "todo", "clarify"))


def _refuse_unguarded(tool_name=None, args=None, **_):
    """Stands in when Ask first could not load: anything it would have checked is refused."""
    try:
        from .ask_first import NoScreen, classify
        from .sign_ins import shows_a_computer
        risky = shows_a_computer(tool_name, args) or classify(tool_name, args, screen=NoScreen()) is not None
    except Exception:
        risky = tool_name not in _LOOKS
    if risky:
        return {"action": "block", "message": "Not done: Nollie's safety check didn't start, so actions that send, "
                                              "buy, post, delete or use a computer are off until it's fixed."}
    return None
