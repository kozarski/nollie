"""Run the crew against Hermes's real profile and cron code in a temporary home.

Started by test_hermes.py in a child process whose HOME and HERMES_HOME are temporary.
Prints one JSON object with what it saw.
"""
import contextlib
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import pwd
import sys

root = Path(os.environ["HERMES_HOME"]).resolve()
real = (Path(pwd.getpwuid(os.getuid()).pw_dir) / ".hermes").resolve()
if not str(root).startswith(os.environ["CREW_SCENARIO_TMP"]) or str(root).startswith(str(real)):
    sys.exit("refusing to run outside a temporary home")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import NOLLIE, PACKAGE, install_workflow, store  # noqa: E402
from hermes_cli import profiles as hp  # noqa: E402
from cron.jobs import get_job  # noqa: E402

crew_module = importlib.import_module(PACKAGE + ".crew")
hermes_profiles = importlib.import_module(PACKAGE + ".hermes_profiles")
tools_module = importlib.import_module(PACKAGE + ".tools")

store.write_yaml(root / "config.yaml", NOLLIE)
install_workflow(root)
with contextlib.redirect_stdout(io.StringIO()):
    hp.create_profile("career", no_alias=True)
    hp.set_profile_display_name("career", "Scout")
    hp.create_profile("private", no_alias=True)


def digest(path):
    h = hashlib.sha256()
    for item in sorted(Path(path).rglob("*")):
        h.update(str(item.relative_to(path)).encode())
        if item.is_file():
            h.update(item.read_bytes())
    return h.hexdigest()


private_before = digest(hp.get_profile_dir("private"))
profiles = hermes_profiles.HermesProfiles()
crew = crew_module.Crew(profiles, profiles.home("default") / "nollie-crew")
tools = tools_module.CrewTools(crew, hermes_profiles.caller)
seen = {}


def call(tool, args):
    return json.loads(tools.handle(tool, args))


seen["caller"] = hermes_profiles.caller()
seen["clash"] = call("crew_add", {"name": "Scout", "role": "x y", "come_to_me_for": "Things.", "asked_by_person": True})
added = call("crew_add", {"name": "Rover", "role": "check new roles each morning",
                          "come_to_me_for": "New job listings.", "asked_by_person": True,
                          "schedule": {"when": "0 8 * * *", "task": "Check new roles.", "asked_by_person": True}})
seen["added"] = added
seen["names_after_add"] = hp.list_profile_names()
rover = hp.get_profile_dir("rover")
seen["meta"] = hp.read_profile_meta(rover)
config = store.read_yaml(rover / "config.yaml")
seen["model"] = config.get("model")
seen["exceeds"] = crew_module.policy.exceeds(config, NOLLIE)
seen["cli_tools"] = config["platform_toolsets"]["cli"]
seen["wrapper"] = (Path.home() / ".local" / "bin" / "rover").exists()
job_id = crew.read_state()["members"]["rover"]["jobs"][0]
with hermes_profiles.home_scope(rover):
    seen["job"] = {k: get_job(job_id).get(k) for k in ("enabled", "state", "deliver")}
seen["pause"] = call("crew_pause", {"name": "Rover"})
seen["parked"] = hp.profile_is_parked(rover)
with hermes_profiles.home_scope(rover):
    seen["job_paused"] = get_job(job_id).get("enabled")
seen["served_while_parked"] = [n for n, _ in hp.profiles_to_serve(True)]
call("crew_resume", {"name": "Rover"})
seen["ask_retire"] = call("crew_retire", {"name": "Rover"})["status"]
retired = call("crew_retire", {"name": "Rover", "confirm": True})
seen["retired"] = retired["status"]
seen["names_after_retire"] = hp.list_profile_names()
seen["archives"] = [p.name.endswith(".tar.gz") for p in (root / "nollie-crew" / "archives").iterdir()]
back = call("crew_undo", {"token": retired["undo"]})
seen["back"] = back["status"]
seen["names_after_undo"] = hp.list_profile_names()
with hermes_profiles.home_scope(rover):
    seen["job_after_undo"] = bool(get_job(job_id))
seen["undo_add"] = call("crew_undo", {"token": added["undo"]})["status"]
seen["names_at_end"] = hp.list_profile_names()
seen["private_untouched"] = digest(hp.get_profile_dir("private")) == private_before
print(json.dumps(seen, default=str))
