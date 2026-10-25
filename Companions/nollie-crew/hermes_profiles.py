"""Hermes's own profile code for the lifecycle; plain files for everything this add-on wrote.

Imported only inside Hermes. Creating, deleting, archiving and restoring use
``hermes_cli.profiles``; schedules use ``cron.jobs`` scoped to the member's home; pausing
uses Hermes's parked marker and asks the running host to stop or start serving the member.
"""
import contextlib
from contextvars import ContextVar
import io
from pathlib import Path
import tarfile
import threading

from . import store
from .policy import CrewError, MAIN, PRIVATE
from .profiles import FileProfiles, MARKER

_PREPARE_MEMBER = ContextVar("nollie_crew_prepare_member", default=None)
_LAYOUT_LOCK = threading.Lock()


def prepare_member_layout(profiles):
    with _LAYOUT_LOCK:
        finish = getattr(profiles, "_finish_profile_layout", None)
        if finish is None:
            raise CrewError("Hermes needs updating before adding a crew member.")
        if getattr(finish, "_nollie_crew_context", None) is _PREPARE_MEMBER:
            return

        def finish_member(staging, **kwargs):
            prepare = _PREPARE_MEMBER.get()
            if prepare is None:
                return finish(staging, **kwargs)
            return prepare(finish, Path(staging), kwargs)

        finish_member._nollie_crew_context = _PREPARE_MEMBER
        profiles._finish_profile_layout = finish_member


@contextlib.contextmanager
def home_scope(path):
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    token = set_hermes_home_override(str(path))
    try:
        yield
    finally:
        reset_hermes_home_override(token)


@contextlib.contextmanager
def quiet():
    """Hermes's profile commands print progress for the terminal; keep it out of tool output."""
    with contextlib.redirect_stdout(io.StringIO()):
        yield


class HermesProfiles(FileProfiles):
    def __init__(self, root=None):
        from hermes_cli.profiles import get_profile_dir
        super().__init__(Path(get_profile_dir(MAIN)) if root is None else root)

    def home(self, profile_id):
        from hermes_cli.profiles import get_profile_dir
        home = Path(get_profile_dir(profile_id))
        if profile_id != MAIN:
            self.workflow.check_home(profile_id, home)
        return home

    def profile_ids(self):
        from hermes_cli.profiles import list_profile_names
        return list(list_profile_names())

    def display_name(self, profile_id):
        if profile_id == PRIVATE:
            raise PermissionError("the private profile is never read")
        from hermes_cli.profiles import read_profile_meta
        return read_profile_meta(self.home(profile_id)).get("display_name", "")

    def platforms(self):
        try:
            from hermes_cli.platforms import PLATFORMS
            return tuple(PLATFORMS)
        except Exception:
            return ()

    def write_meta(self, profile_id, *, display_name=None, description=None):
        from hermes_cli.profiles import write_profile_meta
        write_profile_meta(self.home(profile_id), display_name=display_name, description=description,
                           description_auto=False if description is not None else None)

    def create(self, profile_id, *, config, soul, display_name, description, marker):
        from hermes_cli import profiles
        profiles.validate_profile_name(profile_id)
        self.workflow.prepare(profile_id)
        prepare_member_layout(profiles)
        home = self.home(profile_id)

        def finish_member(finish, staging, kwargs):
            if staging.parent != home.parent or not staging.name.startswith(f".{profile_id}.staging-"):
                raise CrewError("Hermes needs updating before adding a crew member.")
            # The gateway cannot see this hidden folder until the rules and tools are ready.
            self.workflow.copy_into(profile_id, staging)
            store.write_yaml(staging / "config.yaml", config)
            self.workflow.mark_initialized(staging)
            finish(staging, **kwargs)
            store.write_json(staging / MARKER, marker)
            store.write_text(staging / "SOUL.md", soul)
            profiles.write_profile_meta(staging, display_name=display_name, description=description,
                                        description_auto=False)

        token = _PREPARE_MEMBER.set(finish_member)
        try:
            with quiet():
                profiles.create_profile(profile_id, no_alias=True, description=description)
        finally:
            _PREPARE_MEMBER.reset(token)

    def archive(self, profile_id, folder):
        import time
        import uuid
        from hermes_cli.profiles import export_profile
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        base = folder / f"{profile_id}-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}"
        with quiet():
            path = Path(export_profile(profile_id, str(base)))
        path.chmod(0o600)
        return str(path)

    def remove(self, profile_id):
        if profile_id in (MAIN, PRIVATE):
            raise PermissionError("never removed")
        from hermes_cli.profiles import ProfileIdentitySettlementPending, delete_profile
        with quiet():
            try:
                delete_profile(profile_id, yes=True)
            except ProfileIdentitySettlementPending:
                pass  # files are gone; the running host settles routing identity on its own

    def restore(self, archive_path, profile_id):
        self.workflow.prepare(profile_id)
        from hermes_constants import clear_named_profile_deleted
        home = self.home(profile_id)
        if home.exists():
            raise FileExistsError(profile_id)
        # Deleting left a tombstone that would hide the restored profile; create_profile clears it too.
        clear_named_profile_deleted(home)
        super().restore(archive_path, profile_id)
        self._serve(profile_id, True)

    def _restore_home(self, restored, profile_id):
        from hermes_cli.profiles import import_profile
        archive_path = restored.parent / "ready.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            archive.add(restored, arcname=profile_id)
        with quiet():
            import_profile(str(archive_path), profile_id)

    def park(self, profile_id):
        super().park(profile_id)
        self._serve(profile_id, False)

    def unpark(self, profile_id):
        super().unpark(profile_id)
        self._serve(profile_id, True)

    @staticmethod
    def _serve(profile_id, serve):
        """Best effort: the host rescans profiles on its own within about 30 seconds."""
        with contextlib.suppress(Exception):
            from hermes_cli.gateway_multiplex_served import live_default_gateway_pid
            if live_default_gateway_pid() is None:
                return
            from hermes_constants import get_default_hermes_root
            from gateway.control_socket import request_serve_profile_hot, request_unserve_profile
            (request_serve_profile_hot if serve else request_unserve_profile)(get_default_hermes_root(), profile_id)

    # Schedules --------------------------------------------------------------------
    def add_schedule(self, profile_id, *, when, task, name):
        from cron.jobs import create_job
        with home_scope(self.home(profile_id)):
            job = create_job(task, when, name=name, deliver="local")
        return job["id"]

    def pause_schedule(self, profile_id, job_id):
        from cron.jobs import pause_job
        with home_scope(self.home(profile_id)):
            pause_job(job_id, reason="Paused with the crew member")

    def resume_schedule(self, profile_id, job_id):
        from cron.jobs import resume_job
        with home_scope(self.home(profile_id)):
            resume_job(job_id)

    def remove_schedule(self, profile_id, job_id):
        from cron.jobs import remove_job
        with home_scope(self.home(profile_id)):
            remove_job(job_id)

    def schedules(self, profile_id):
        from cron.jobs import list_jobs
        with home_scope(self.home(profile_id)):
            return list_jobs(include_disabled=True)


def caller():
    """Who is calling, from Hermes's own context: profile, and whether it is a helper or a schedule."""
    from hermes_cli.profiles import current_profile_name
    profile = current_profile_name("default")
    helper = scheduled = False
    with contextlib.suppress(Exception):
        from agent.subagent_lifecycle import get_active_subagent_parent
        # Every turn binds its own agent here; a delegated helper is one with a delegation depth.
        agent = get_active_subagent_parent()
        helper = agent is not None and int(getattr(agent, "_delegate_depth", 0) or 0) > 0
    with contextlib.suppress(Exception):
        from cron.execution_identity import current_cron_execution
        scheduled = current_cron_execution() is not None
    return {"profile": profile, "helper": helper, "scheduled": scheduled}
