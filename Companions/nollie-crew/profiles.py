"""Where crew members live: Hermes profiles under ``<root>/profiles/<id>``.

``FileProfiles`` reads and writes the profile files directly and is what the tests use.
``HermesProfiles`` (in ``hermes_profiles.py``) keeps those file operations and hands
creating, deleting, archiving and serving to Hermes's own profile code.
"""
from pathlib import Path
from datetime import datetime
import copy
import shutil
import tarfile
import time
import uuid

from . import policy, store
from .policy import MAIN, PRIVATE, PROFILE_ID
from .workflow import Workflow

MARKER = "nollie-crew.json"
PARKED = "gateway.parked"


class FileProfiles:
    def __init__(self, root):
        self.root = Path(root)
        self.workflow = Workflow(self.root)

    def is_private(self, profile_id):
        return self.workflow.is_private(profile_id)

    # Names --------------------------------------------------------------------------
    def home(self, profile_id):
        if profile_id == MAIN:
            return self.root
        if not PROFILE_ID.match(profile_id or ""):
            raise ValueError("invalid profile id")
        home = self.root / "profiles" / profile_id
        self.workflow.check_home(profile_id, home)
        return home

    def profile_ids(self):
        ids = [MAIN]
        folder = self.root / "profiles"
        if folder.is_dir():
            for entry in sorted(folder.iterdir()):
                if entry.is_dir() and PROFILE_ID.match(entry.name) and any(
                        (entry / marker).exists() for marker in ("config.yaml", ".env", "SOUL.md", "profile.yaml")):
                    ids.append(entry.name)
        return ids

    def display_name(self, profile_id):
        if profile_id == PRIVATE:
            raise PermissionError("the private profile is never read")
        meta = store.read_yaml(self.home(profile_id) / "profile.yaml")
        return str(meta.get("display_name") or "").strip()

    def platforms(self):
        return ()

    # Files --------------------------------------------------------------------------
    def read_config(self, profile_id):
        if profile_id == PRIVATE:
            raise PermissionError("the private profile is never read")
        return store.read_yaml(self.home(profile_id) / "config.yaml")

    def read_marker(self, profile_id):
        try:
            value = store.read_json(self.home(profile_id) / MARKER)
        except (ValueError, OSError):
            return None
        return value if isinstance(value, dict) else None

    def snapshot(self, profile_id):
        home = self.home(profile_id)
        meta = store.read_yaml(home / "profile.yaml")
        soul = home / "SOUL.md"
        return {"config": store.read_yaml(home / "config.yaml"),
                "soul": soul.read_text(encoding="utf-8") if soul.exists() else "",
                "display_name": str(meta.get("display_name") or ""),
                "description": str(meta.get("description") or "")}

    def write_files(self, profile_id, *, config=None, soul=None, display_name=None, description=None, marker=None):
        self.workflow.prepare(profile_id)
        home = self.home(profile_id)
        path = home / "config.yaml"
        if path.is_symlink():
            raise policy.CrewError("The bot's settings need repair.")
        current = store.read_yaml(path)
        config = copy.deepcopy(config) if config is not None else current
        initialized = self.workflow.initialized(home)
        policy.require_workflow(config, choice=current if initialized else None)
        if policy.exceeds(config, self.read_config(MAIN), require_ask_first=not initialized):
            raise policy.CrewError("That would give the crew member more than Nollie has.")
        self.workflow.ensure_into(profile_id, home)
        if marker is not None:  # first, so a half-made profile can still be recognised as ours
            store.write_json(home / MARKER, marker)
        if config != store.read_yaml(path):
            if path.exists():
                backup = path.with_name(f"config.yaml.bak-nollie-crew-{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}")
                shutil.copy2(path, backup)
                backup.chmod(0o600)
                if path.read_bytes() != backup.read_bytes():
                    raise OSError("config backup verification failed")
            store.write_yaml(path, config)
        self.workflow.mark_initialized(home)
        if soul is not None:
            store.write_text(home / "SOUL.md", soul)
        if display_name is not None or description is not None:
            self.write_meta(profile_id, display_name=display_name, description=description)

    def write_meta(self, profile_id, *, display_name=None, description=None):
        path = self.home(profile_id) / "profile.yaml"
        meta = store.read_yaml(path)
        if display_name is not None:
            meta["display_name"] = display_name
        if description is not None:
            meta["description"] = description
            meta["description_auto"] = False
        store.write_yaml(path, meta)

    # Lifecycle ----------------------------------------------------------------------
    def create(self, profile_id, *, config, soul, display_name, description, marker):
        self.workflow.prepare(profile_id)
        home = self.home(profile_id)
        if home.exists():
            raise FileExistsError(profile_id)
        staging = home.parent / f".{profile_id}.staging-{uuid.uuid4().hex[:8]}"
        staging.mkdir(parents=True)
        try:
            for sub in ("memories", "sessions", "skills", "logs", "cron", "workspace", "home"):
                (staging / sub).mkdir()
            store.write_text(staging / ".env", "")
            self.workflow.copy_into(profile_id, staging)
            store.write_json(staging / MARKER, marker)
            store.write_yaml(staging / "config.yaml", config)
            self.workflow.mark_initialized(staging)
            store.write_text(staging / "SOUL.md", soul)
            store.write_yaml(staging / "profile.yaml", {"display_name": display_name, "description": description,
                                                       "description_auto": False})
            staging.rename(home)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise

    def archive(self, profile_id, folder):
        """A copy of the member's profile (chats included), never its credentials."""
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = folder / f"{profile_id}-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}.tar.gz"
        home = self.home(profile_id)

        def skip(info):
            name = Path(info.name).name
            return None if name in (".env", "auth.json", "auth.lock") else info

        with tarfile.open(target, "w:gz") as archive:
            archive.add(home, arcname=profile_id, filter=skip)
        target.chmod(0o600)
        return str(target)

    def remove(self, profile_id):
        if profile_id in (MAIN, PRIVATE):
            raise PermissionError("never removed")
        shutil.rmtree(self.home(profile_id))

    def restore(self, archive_path, profile_id):
        self.workflow.prepare(profile_id)
        home = self.home(profile_id)
        if home.exists():
            raise FileExistsError(profile_id)
        staging = home.parent / f".{profile_id}.restore-{uuid.uuid4().hex[:8]}"
        staging.mkdir(parents=True)
        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                archive.extractall(staging, filter="data")
            restored = staging / profile_id
            if (restored / "config.yaml").is_symlink():
                raise policy.CrewError("The bot's settings need repair.")
            config = store.read_yaml(restored / "config.yaml")
            initialized = self.workflow.initialized(restored)
            policy.require_workflow(config, choice=config if initialized else None)
            if policy.exceeds(config, self.read_config(MAIN), require_ask_first=not initialized):
                raise policy.CrewError("That would give the crew member more than Nollie has.")
            self.workflow.copy_into(profile_id, restored, restoring=True)
            store.write_yaml(restored / "config.yaml", config)
            self.workflow.mark_initialized(restored)
            self._restore_home(restored, profile_id)
        finally:
            shutil.rmtree(staging, ignore_errors=True)

    def _restore_home(self, restored, profile_id):
        restored.rename(self.home(profile_id))

    def park(self, profile_id):
        store.write_text(self.home(profile_id) / PARKED, "")

    def unpark(self, profile_id):
        (self.home(profile_id) / PARKED).unlink(missing_ok=True)

    def is_parked(self, profile_id):
        return (self.home(profile_id) / PARKED).exists()

    # Schedules (Hermes's per-profile cron store layout) -----------------------------
    def _jobs_path(self, profile_id):
        return self.home(profile_id) / "cron" / "jobs.json"

    def _jobs(self, profile_id):
        value = store.read_json(self._jobs_path(profile_id), {"jobs": []})
        return value if isinstance(value, dict) else {"jobs": []}

    def add_schedule(self, profile_id, *, when, task, name):
        jobs = self._jobs(profile_id)
        job_id = uuid.uuid4().hex[:12]
        jobs.setdefault("jobs", []).append({"id": job_id, "name": name, "schedule": when, "prompt": task,
                                            "enabled": True, "state": "scheduled", "deliver": "local"})
        store.write_json(self._jobs_path(profile_id), jobs)
        return job_id

    def _set_job(self, profile_id, job_id, **values):
        jobs = self._jobs(profile_id)
        for job in jobs.get("jobs", []):
            if job.get("id") == job_id:
                job.update(values)
        store.write_json(self._jobs_path(profile_id), jobs)

    def pause_schedule(self, profile_id, job_id):
        self._set_job(profile_id, job_id, enabled=False, state="paused")

    def resume_schedule(self, profile_id, job_id):
        self._set_job(profile_id, job_id, enabled=True, state="scheduled")

    def remove_schedule(self, profile_id, job_id):
        jobs = self._jobs(profile_id)
        jobs["jobs"] = [job for job in jobs.get("jobs", []) if job.get("id") != job_id]
        store.write_json(self._jobs_path(profile_id), jobs)

    def schedules(self, profile_id):
        return [job for job in self._jobs(profile_id).get("jobs", []) if isinstance(job, dict)]

