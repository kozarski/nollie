"""Pure crew rules: names, what a member may have, what needs the person, and the words people see.

Nothing here touches disk. ``crew.py`` applies these rules to Hermes profiles.
"""
import copy
import hashlib
import json
import re

MAIN = "default"            # Nollie, the main assistant
PRIVATE = "private"         # Moss: never touched, never read beyond its name
WORKFLOW = "nollie-workflow"
CAP = 8                     # crew members this add-on may run at once (active or paused)

# Hermes refuses these profile ids, plus the ids and names that already mean something here.
RESERVED_IDS = frozenset({"hermes", "default", "test", "tmp", "root", "sudo", PRIVATE, "nollie", "ollie",
                          "chat", "model", "gateway", "setup", "whatsapp", "login", "logout", "status",
                          "cron", "doctor", "dump", "config", "pairing", "skills", "tools", "mcp",
                          "connections", "sessions", "insights", "version", "update", "uninstall",
                          "profile", "plugins", "honcho", "acp"})
# Moss is the private profile's name; its files are never opened to learn it.
RESERVED_NAMES = frozenset({"nollie", "ollie", "moss"})

PROFILE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
DISPLAY_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9 '\-]{0,31}$")

# What each kind of toolset means for the person.
MAC = "mac"
PLAN = "plan"
CONNECTIONS = "connections"
SCHEDULE = "schedule"
MESSAGES = "messages"
NEED_ORDER = (MAC, PLAN, CONNECTIONS, SCHEDULE, MESSAGES)
NEED_WORDS = {
    MAC: "use the Mac",
    PLAN: "use your online plan",
    CONNECTIONS: "use your connections",
    SCHEDULE: "run on a schedule I picked",
    MESSAGES: "send messages to other people",
}

MAC_TOOLSETS = frozenset({"computer_use"})
CONNECTION_TOOLSETS = frozenset({"connections"})
SCHEDULE_TOOLSETS = frozenset({"cronjob"})
MESSAGE_TOOLSETS = frozenset({"discord", "discord_admin", "yuanbao", "feishu_doc", "feishu_drive",
                              "send_message", "messaging", "bot_room"})
# Never handed to a member: the crew tools themselves and app-only surfaces.
NEVER_TOOLSETS = frozenset({"nollie_crew", "project", "desktop_ui", "onboarding", "catalog"})
DEFAULT_TOOLSETS = ("web", "file", "todo", "memory", "session_search", "skills", "clarify", "vision")
# A member's config lists toolsets explicitly for these, so no Hermes default can grant more.
CORE_PLATFORMS = ("cli", "api_server", "cron", "webhook")

LOCAL_PROVIDERS = frozenset({"llamacpp", "llama.cpp", "llama-cpp", "ollama", "lmstudio", "lm-studio", "local"})
LOCAL_HOSTS = ("localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0")

# Settings copied from Nollie because they shape behaviour, not reach. Everything else
# (channels, plan sign-ins, secrets, connections, gateway, voice providers) stays with Nollie.
COPIED_ROOTS = ("_config_version", "agent", "attachments", "browser", "checkpoints", "code_execution",
                "compression", "context", "curator", "database", "delegation", "display", "kanban",
                "known_builtin_toolsets", "known_plugin_toolsets", "local_runtime", "memory", "privacy",
                "prompt_caching", "runtime", "security", "sessions", "skills", "streaming", "telemetry",
                "terminal", "timezone", "tool_loop_guardrails", "tool_output", "tools", "update", "updates",
                "web")
APPROVAL_MODES = ("manual", "smart")


class CrewError(ValueError):
    """A request that breaks a rule; the message is plain enough to show the person."""


# Names ---------------------------------------------------------------------------------

def clean_name(name):
    if not isinstance(name, str) or not DISPLAY_NAME.match(name.strip()):
        raise CrewError("A crew member needs a short name made of letters, like Scout.")
    return " ".join(name.split())


def profile_id_for(name):
    candidate = re.sub(r"[^a-z0-9]+", "-", clean_name(name).lower()).strip("-")[:64]
    if not PROFILE_ID.match(candidate):
        raise CrewError("A crew member needs a short name made of letters, like Scout.")
    return candidate


def check_name_free(name, profile_id, existing_ids, existing_names):
    """``existing_names`` holds the display names of every profile except the private one."""
    folded = name.casefold()
    if profile_id in RESERVED_IDS or folded in RESERVED_NAMES:
        raise CrewError(f"The name {name} is already taken. Pick another one.")
    taken = {i.casefold() for i in existing_ids} | {n.casefold() for n in existing_names if n}
    if profile_id in existing_ids or folded in taken or profile_id.casefold() in taken:
        raise CrewError(f"The name {name} is already taken. Pick another one.")


def clean_role(role):
    if not isinstance(role, str) or not role.strip():
        raise CrewError("Say what the crew member does, like 'check new roles each morning'.")
    role = " ".join(role.split()).rstrip(".")
    if len(role) > 120:
        raise CrewError("Keep the role under 120 characters.")
    if role[0].isupper() and (len(role) == 1 or role[1].islower()):
        role = role[0].lower() + role[1:]
    return role


def clean_come_to_me_for(text):
    if not isinstance(text, str) or not text.strip():
        raise CrewError("Write one or two sentences for 'come to me for'.")
    text = " ".join(text.split())
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    if len(sentences) > 2 or len(text) > 280:
        raise CrewError("Keep 'come to me for' to one or two short sentences.")
    return text if text[-1] in ".!?" else text + "."


# What Nollie has -----------------------------------------------------------------------

def _string_list(value):
    if isinstance(value, str):
        value = [part.strip() for part in value.strip("[]").replace("'", "").replace('"', "").split(",")]
    return [str(item).strip() for item in (value or []) if str(item).strip()]


def nollie_platform_toolsets(nollie):
    raw = nollie.get("platform_toolsets") or {}
    return {str(platform): _string_list(names) for platform, names in raw.items()} if isinstance(raw, dict) else {}


def nollie_mcp_servers(nollie):
    servers = nollie.get("mcp_servers") or {}
    return servers if isinstance(servers, dict) else {}


def nollie_disabled_toolsets(nollie):
    return set(_string_list((nollie.get("agent") or {}).get("disabled_toolsets")))


def nollie_toolsets(nollie):
    """Toolset names Nollie can use anywhere, minus the ones Nollie has switched off."""
    names = set()
    for listed in nollie_platform_toolsets(nollie).values():
        names.update(name for name in listed if not name.startswith("hermes-"))
    names.update(name for name in _string_list(nollie.get("toolsets")) if not name.startswith("hermes-"))
    return names - nollie_disabled_toolsets(nollie) - set(nollie_mcp_servers(nollie))


def is_local_model(model, providers=None):
    if isinstance(model, str):
        return False
    if not isinstance(model, dict):
        return False
    provider = str(model.get("provider") or "").strip().lower()
    if provider in LOCAL_PROVIDERS:
        return True
    base_url = str(model.get("base_url") or "")
    if not base_url and isinstance(providers, dict) and isinstance(providers.get(provider), dict):
        base_url = str(providers[provider].get("base_url") or "")
    host = re.sub(r"^[a-z]+://", "", base_url.lower()).split("/")[0].rsplit(":", 1)[0] if base_url else ""
    return host in LOCAL_HOSTS


def nollie_has_plan(nollie):
    model = nollie.get("model")
    return bool(model) and not is_local_model(model, nollie.get("providers"))


def local_model_block(nollie, settings):
    """The crew's local model: the one recorded at install, else Nollie's own when it is local."""
    chosen = (settings or {}).get("local_model")
    if isinstance(chosen, dict) and chosen.get("provider"):
        return {"model": copy.deepcopy(chosen)}
    model = nollie.get("model")
    if model and is_local_model(model, nollie.get("providers")):
        block = {"model": copy.deepcopy(model)}
        provider = model.get("provider")
        providers = nollie.get("providers") or {}
        if isinstance(providers, dict) and provider in providers:
            block["providers"] = {provider: copy.deepcopy(providers[provider])}
        return block
    return {"model": {"provider": "llamacpp"}}


# A member's reach ---------------------------------------------------------------------

def classify(toolset, mcp_servers):
    if toolset in mcp_servers:
        definition = json.dumps(mcp_servers.get(toolset) or {}, sort_keys=True).lower()
        return MAC if (toolset.startswith("cua") or "cua" in definition) else CONNECTIONS
    if toolset in MAC_TOOLSETS:
        return MAC
    if toolset in CONNECTION_TOOLSETS:
        return CONNECTIONS
    if toolset in SCHEDULE_TOOLSETS:
        return SCHEDULE
    if toolset in MESSAGE_TOOLSETS or toolset.startswith("hermes-"):
        return MESSAGES
    return None


def resolve_reach(nollie, toolsets=None, model_route=None):
    """Check a request against Nollie and return the member's reach: toolsets, MCP servers, route."""
    route = (model_route or "local").strip().lower() if isinstance(model_route, (str, type(None))) else None
    if route not in ("local", "plan"):
        raise CrewError("The model route is either 'local' or 'plan'.")
    if route == "plan" and not nollie_has_plan(nollie):
        raise CrewError("Nollie isn't using an online plan, so a crew member can't either.")
    mcp = nollie_mcp_servers(nollie)
    available = nollie_toolsets(nollie)
    if toolsets is None:
        wanted = [name for name in DEFAULT_TOOLSETS if name in available]
    else:
        if isinstance(toolsets, str) or not isinstance(toolsets, list):
            raise CrewError("Toolsets must be a list of names.")
        wanted = []
        for name in toolsets:
            name = str(name).strip()
            if not name or name in wanted:
                continue
            if name in NEVER_TOOLSETS:
                raise CrewError(f"Crew members can't have {name}.")
            if name not in available and name not in mcp:
                raise CrewError(f"Nollie doesn't have {name}, so a crew member can't either.")
            if name in nollie_disabled_toolsets(nollie):
                raise CrewError(f"Nollie has {name} switched off, so a crew member can't have it.")
            wanted.append(name)
    return {"toolsets": sorted(t for t in wanted if t not in mcp),
            "mcp_servers": sorted(t for t in wanted if t in mcp), "model_route": route}


def clean_schedule(schedule):
    if schedule is None:
        return None
    if not isinstance(schedule, dict):
        raise CrewError("A schedule needs 'when' and 'task'.")
    when = str(schedule.get("when") or "").strip()
    task = " ".join(str(schedule.get("task") or "").split())
    if not when or len(when) > 64 or not task or len(task) > 500:
        raise CrewError("A schedule needs 'when' (like '0 8 * * *') and a short 'task'.")
    return {"when": when, "task": task, "asked_by_person": schedule.get("asked_by_person") is True}


def needs_for(reach, schedule, nollie, *, before=None):
    """What the person has to agree to. ``before`` is the member's current reach on an update."""
    mcp = nollie_mcp_servers(nollie)
    needs = set()
    old = set((before or {}).get("toolsets", [])) | set((before or {}).get("mcp_servers", []))
    for name in list(reach["toolsets"]) + list(reach["mcp_servers"]):
        kind = classify(name, mcp)
        if kind and name not in old:
            needs.add(kind)
    if reach["model_route"] == "plan" and (before or {}).get("model_route") != "plan":
        needs.add(PLAN)
    if schedule is not None and not schedule["asked_by_person"]:
        needs.add(SCHEDULE)
    return [need for need in NEED_ORDER if need in needs]


def member_config(nollie, reach, settings, platforms=()):
    """A member's config.yaml: Nollie's behaviour settings, never more reach than Nollie."""
    cfg = {key: copy.deepcopy(nollie[key]) for key in COPIED_ROOTS if key in nollie}

    approvals = copy.deepcopy(nollie.get("approvals") or {})
    if approvals.get("mode") not in APPROVAL_MODES:
        approvals["mode"] = "manual"
    for key in ("cron_mode", "single_query_mode", "unattended_mode"):
        approvals[key] = "deny"
    approvals["deny"] = list(_string_list(approvals.get("deny")))
    cfg["approvals"] = approvals
    cfg["command_allowlist"] = []  # standing "always" answers stay Nollie's own

    agent = cfg.setdefault("agent", {}) if isinstance(cfg.get("agent", {}), dict) else {}
    cfg["agent"] = agent
    agent["disabled_toolsets"] = sorted(nollie_disabled_toolsets(nollie) | NEVER_TOOLSETS)

    granted = set(reach["toolsets"]) | set(reach["mcp_servers"])
    listed = nollie_platform_toolsets(nollie)
    main = set(listed.get("cli") or nollie_toolsets(nollie)) | set(nollie_mcp_servers(nollie))
    lists = {}
    for platform in sorted(set(listed) | set(CORE_PLATFORMS) | set(platforms)):
        own = [name for name in listed.get(platform, []) if not name.startswith("hermes-")]
        allowed = set(own) if own else main
        lists[platform] = sorted(name for name in granted if name in allowed)
    cfg["platform_toolsets"] = lists
    if nollie.get("toolsets") is not None:
        cfg["toolsets"] = sorted(name for name in _string_list(nollie.get("toolsets")) if name in granted)

    servers = nollie_mcp_servers(nollie)
    cfg["mcp_servers"] = {name: copy.deepcopy(servers[name]) for name in reach["mcp_servers"]}

    cfg["plugins"] = copy.deepcopy(nollie.get("plugins") or {})
    require_workflow(cfg)

    auth = cfg.setdefault("auth", copy.deepcopy(nollie.get("auth") or {}))
    auth["adopt_external_logins"] = False  # never borrow another tool's sign-in

    if reach["model_route"] == "plan":
        cfg["model"] = copy.deepcopy(nollie["model"])
    else:
        cfg.update(local_model_block(nollie, settings))
    cfg["fallback_providers"] = []
    return cfg


def require_workflow(cfg, *, choice=None):
    chosen = copy.deepcopy(choice.get("plugins") or {}) if choice is not None else None
    plugins = cfg.setdefault("plugins", {})
    if not isinstance(plugins, dict):
        raise CrewError("Nollie's add-on settings need repair before adding a crew member.")
    plugins["enabled"] = [p for p in _string_list(plugins.get("enabled")) if p.rsplit("/", 1)[-1] != "nollie-crew"]
    if not any(p.rsplit("/", 1)[-1] == WORKFLOW for p in plugins["enabled"]):
        plugins["enabled"].append(WORKFLOW)
    plugins["disabled"] = sorted({p for p in _string_list(plugins.get("disabled"))
                                  if p.rsplit("/", 1)[-1] != WORKFLOW} | {"nollie-crew"})
    if chosen is not None:
        for key in ("enabled", "disabled"):
            plugins[key] = [p for p in plugins[key] if p.rsplit("/", 1)[-1] != WORKFLOW]
            plugins[key].extend(p for p in _string_list(chosen.get(key)) if p.rsplit("/", 1)[-1] == WORKFLOW)
    if "nollie_sign_in" not in reach_of(cfg)["toolsets"]:
        agent = cfg.setdefault("agent", {})
        agent["disabled_toolsets"] = sorted(set(_string_list(agent.get("disabled_toolsets"))) | {"nollie_sign_in"})


def reach_of(cfg):
    """Read a member's reach back from its config, for checks and undo."""
    lists = cfg.get("platform_toolsets") or {}
    names = set()
    for listed in lists.values():
        names.update(_string_list(listed))
    servers = set((cfg.get("mcp_servers") or {}).keys())
    return {"toolsets": sorted(names - servers), "mcp_servers": sorted(servers)}


def exceeds(member_cfg, nollie, *, require_ask_first=True):
    """Every way a member's config reaches past Nollie's current config (empty means fine)."""
    problems = []
    reach = reach_of(member_cfg)
    available = nollie_toolsets(nollie) | set(nollie_mcp_servers(nollie))
    extra = [name for name in reach["toolsets"] + reach["mcp_servers"] if name not in available]
    if extra:
        problems.append("toolsets: " + ", ".join(sorted(extra)))
    if member_cfg.get("command_allowlist"):
        problems.append("standing approvals")
    nollie_deny = set(_string_list((nollie.get("approvals") or {}).get("deny")))
    member_approvals = member_cfg.get("approvals") or {}
    if not nollie_deny <= set(_string_list(member_approvals.get("deny"))):
        problems.append("approval deny list")
    if member_approvals.get("mode") not in APPROVAL_MODES:
        problems.append("approval mode")
    plugins = member_cfg.get("plugins") or {}
    enabled = {p.rsplit("/", 1)[-1] for p in _string_list(plugins.get("enabled"))}
    disabled = {p.rsplit("/", 1)[-1] for p in _string_list(plugins.get("disabled"))}
    if require_ask_first and (WORKFLOW not in enabled or WORKFLOW in disabled):
        problems.append("Ask first")
    model = member_cfg.get("model")
    if model and not is_local_model(model, member_cfg.get("providers")):
        nollie_model = nollie.get("model") if nollie_has_plan(nollie) else None
        if not isinstance(nollie_model, dict) or model.get("provider") != nollie_model.get("provider"):
            problems.append("plan access")
    for key in ("platforms", "nous", "secrets"):
        if member_cfg.get(key):
            problems.append(key)
    return problems


# Words people see ----------------------------------------------------------------------

def join_words(items):
    items = list(items)
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


def added_note(name, role):
    return f"I've added {name} to {role}."


def suggestion_note(name, role, needs):
    extra = f" They would {join_words(NEED_WORDS[n] for n in needs)}." if needs else ""
    return f"Want me to add {name} to {role}?{extra}"


def approval_message(action, name, needs):
    return f"Nollie wants to {action} {name} and let them {join_words(NEED_WORDS[n] for n in needs)}."


def retire_question(name):
    return f"Retire {name}? I'll keep a copy of their chats, and you can undo it."


def persona(name, role, come_to_me_for):
    return (
        f"# {name}\n\n"
        f"You are {name}, part of Nollie's crew. Your job: {role}.\n\n"
        f"Come to me for: {come_to_me_for}\n\n"
        "## How you work\n\n"
        "- Nollie leads the crew and talks with the person. Do the work Nollie or the person hands you, "
        "then report back plainly.\n"
        "- Be warm and brief. Ask one question at a time, only when you need to.\n"
        "- Ask first before using the Mac, an online plan or a connection, before setting up a new schedule, "
        "and before anything that messages other people.\n"
        "- Don't pass work to another bot unless Nollie asked you to.\n"
        "- When a page asks for a login, a CAPTCHA or a payment, stop and hand it to the person.\n"
    )


def request_digest(tool, args):
    payload = json.dumps({"tool": tool, "args": args}, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(payload.encode()).hexdigest()[:24]


def idea_words(text):
    stop = {"a", "an", "and", "the", "to", "for", "of", "on", "in", "each", "every", "my", "new", "with"}
    return sorted({w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in stop})


def same_idea(words, other):
    a, b = set(words), set(other)
    return bool(a and b) and len(a & b) / len(a | b) >= 0.6
