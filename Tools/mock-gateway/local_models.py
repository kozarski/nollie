"""Local models on this Mac, as Hermes 0.23.1 serves them, for the mock gateway.

The catalog and hardware are what a real Hermes 0.23.1 answered on a Mac with 192 GB memory
(fixtures/local-models.json). A quick start runs as a job whose progress follows the clock, in
Hermes's own shapes (status, phase, done_bytes, total_bytes, bytes_per_sec, eta_seconds,
can_pause, can_resume, error), so the app's progress, pause, failure and first reply can be seen.

The scenario is chosen with `--local-models <name>` or POST /api/_mock/local-models {"scenario": ...}:
  flow             the download runs for about 40 seconds, then the model answers hello (default)
  downloading      the download stays part way, moving slowly
  paused           the download is paused part way
  failed-network   the download stops: the host can't be reached
  failed-disk      the download stops: no space left on the disk
  failed-checksum  the engine's download did not match its pinned checksum
  ready            the model is already downloaded and chosen
  restarting       as ready, but Hermes has just restarted: the catalog and hardware answer 503 for 12 seconds
                   (or {"seconds": n} in the POST)
"""
import json
import sys
import time
import uuid
from pathlib import Path

FIXTURE = json.loads((Path(__file__).with_name("fixtures") / "local-models.json").read_text())
SCENARIOS = ("flow", "downloading", "paused", "failed-network", "failed-disk", "failed-checksum", "ready", "restarting")
RESTART_SECONDS = 12.0
REPLY = "Hi! Ready when you are."
ENGINE_BYTES = 12_201_717
# The optional draft each catalog entry downloads last (hermes_cli/local_runtime/catalog.json in 0.23.1). Hermes
# counts the model's own files first, then starts the count again for the draft, as a real quick start shows.
DRAFT_BYTES = {"qwen3.8-27b": 1_143_006_816}
FLOW_SECONDS = 40.0
# Hermes's own error words (pm/downloader.py and the OS), as the job's "error" carries them.
ERRORS = {
    "failed-network": "download failed from https://huggingface.co/unsloth/model.gguf: "
                      "<urlopen error [Errno 8] nodename nor servname provided, or not known>",
    "failed-disk": "[Errno 28] No space left on device",
    "failed-checksum": "sha256 mismatch for https://github.com/ggml-org/llama.cpp/releases/engine.zip: pinned 0a1b, got 9f8e",
}


def _scenario_from_argv() -> str:
    if "--local-models" in sys.argv:
        at = sys.argv.index("--local-models")
        if at + 1 < len(sys.argv) and sys.argv[at + 1] in SCENARIOS:
            return sys.argv[at + 1]
    return "flow"


STATE: dict = {}


def reset(scenario: str | None = None) -> None:
    STATE.clear()
    STATE.update(scenario=scenario or _scenario_from_argv(), jobs={}, selected=None, downloaded=set(), since=time.time())
    if STATE["scenario"] in ("ready", "restarting"):
        entry = _entries()[0]
        STATE["downloaded"].add(entry["id"])
        STATE["selected"] = entry["model_id"]


def _entries() -> list[dict]:
    return FIXTURE["catalog"]["models"]


def _entry(model_id: str | None) -> dict | None:
    return next((e for e in _entries() if e["id"] == model_id), None)


def _catalog() -> dict:
    rows = []
    for entry in _entries():
        row = dict(entry)
        done = entry["id"] in STATE["downloaded"]
        row.update(downloaded=done, downloaded_model_id=entry.get("model_id") if done else None)
        rows.append(row)
    return dict(models=rows)


def _progress(job: dict) -> float:
    """How far the job has come, 0 to 1, by the clock and the scenario."""
    scenario = job["scenario"]
    if scenario in ("downloading", "paused"):
        return 0.42 + (0.0005 * (time.time() - job["started_at"]) if scenario == "downloading" else 0)
    if scenario.startswith("failed-"):
        return 0.31
    elapsed = time.time() - job["started_at"] - job["paused_seconds"]
    if job["status"] == "paused":
        elapsed = job["paused_at"] - job["started_at"] - job["paused_seconds"]
    return max(0.0, min(1.0, elapsed / FLOW_SECONDS))


def _view(job: dict) -> dict:
    entry = _entry(job["model_id"])
    total = entry["size_bytes"]
    fraction = _progress(job)
    view = {k: job[k] for k in ("job_id", "kind", "target", "model_id", "started_at", "status")}
    view.update(error=None, detail="", phase="downloading", total_bytes=total, done_bytes=int(total * min(fraction, 1)))
    scenario = job["scenario"]
    if scenario.startswith("failed-"):
        view.update(status="error", error=ERRORS[scenario])
        if scenario == "failed-checksum":
            view.update(phase="downloading-runtime", total_bytes=ENGINE_BYTES, done_bytes=ENGINE_BYTES)
        return dict(view, can_pause=False, can_resume=False, pause_requested=False,
                    percent=round(view["done_bytes"] / view["total_bytes"] * 100))
    if job["status"] == "paused" or scenario == "paused":
        view.update(status="paused")
    elif scenario == "flow" and fraction < 0.06:
        view.update(phase="downloading-runtime", detail="Downloading the local engine", total_bytes=ENGINE_BYTES,
                    done_bytes=int(ENGINE_BYTES * fraction / 0.06))
    elif scenario in ("flow", "downloading") and fraction < 1 and entry["id"] in DRAFT_BYTES:
        draft = DRAFT_BYTES[entry["id"]]
        files = total - draft
        if fraction < files / total:
            view.update(detail=f"Downloading {entry['display_name']}", total_bytes=files, done_bytes=int(total * fraction))
        else:
            view.update(detail="Downloading the draft model that speeds up generation", total_bytes=draft,
                        done_bytes=int(total * fraction) - files)
    if scenario == "flow" and fraction >= 1:
        if job["status"] == "running" and time.time() - job["started_at"] - job["paused_seconds"] < FLOW_SECONDS + 3:
            view.update(phase="starting-server", detail="Starting the local server", done_bytes=total)
        else:
            job["status"] = "done"
            STATE["downloaded"].add(entry["id"])
            STATE["selected"] = entry["model_id"]
            view.update(status="done", phase="done", done_bytes=total, detail=f"{entry['display_name']} is ready — new chats use it")
    running = view["status"] == "running"
    if running and view["phase"] == "downloading":
        rate = total * 0.0005 if scenario == "downloading" else total / FLOW_SECONDS
        view.update(bytes_per_sec=rate, eta_seconds=round((view["total_bytes"] - view["done_bytes"]) / rate))
    view.update(can_pause=running and view["phase"] in ("downloading", "downloading-runtime"),
                can_resume=view["status"] == "paused", pause_requested=False,
                percent=min(100, round(view["done_bytes"] / view["total_bytes"] * 100)))
    return view


def local_models_rest(method: str, base: str, query: dict, body) -> tuple[int, object] | None:
    if not STATE:
        reset()
    fields = body if isinstance(body, dict) else {}
    if base == "/api/_mock/local-models" and method == "POST":
        scenario = fields.get("scenario")
        if scenario not in SCENARIOS:
            return 422, dict(detail="unknown scenario")
        reset(scenario)
        if isinstance(fields.get("seconds"), (int, float)):
            STATE["restart_seconds"] = float(fields["seconds"])
        return 200, dict(ok=True, scenario=scenario)
    if base == "/api/model/options" and method == "GET" and STATE["selected"]:
        return 200, dict(model=STATE["selected"], provider="llamacpp",
                         providers=[dict(slug="llamacpp", name="llama.cpp", authenticated=True, is_current=True,
                                         models=[STATE["selected"]], featured_models=[])])
    if not base.startswith(("/api/local-models", "/api/nollie/local-model")):
        return None
    if (STATE["scenario"] == "restarting" and base in ("/api/local-models/hardware", "/api/local-models/catalog")
            and time.time() - STATE["since"] < STATE.get("restart_seconds", RESTART_SECONDS)):
        return 503, dict(detail="Local models are starting")
    if base == "/api/local-models/hardware":
        return 200, FIXTURE["hardware"]
    if base == "/api/local-models/catalog":
        return 200, _catalog()
    if base == "/api/local-models/quickstart" and method == "POST":
        entry = _entry(fields.get("model_id"))
        if entry is None:
            return 404, dict(detail=f"unknown model {fields.get('model_id')}")
        if any(j["status"] in ("running", "paused") for j in STATE["jobs"].values()):
            return 409, dict(detail="Setup is already running")
        job = dict(job_id=uuid.uuid4().hex[:12], kind="quickstart", target=entry["display_name"], model_id=entry["id"],
                   started_at=time.time(), status="running", scenario=STATE["scenario"], paused_seconds=0.0, paused_at=None)
        if job["scenario"] == "paused":
            job.update(status="paused", paused_at=time.time())
        STATE["jobs"][job["job_id"]] = job
        return 200, dict(job_id=job["job_id"], model_id=entry["id"], display_name=entry["display_name"],
                         needs_runtime=True, needs_download=True, download_bytes=entry["size_bytes"])
    if base == "/api/local-models/jobs":
        views = sorted((_view(j) for j in STATE["jobs"].values()), key=lambda v: -v["started_at"])
        return 200, dict(jobs=views)
    if base.startswith("/api/local-models/jobs/"):
        job = STATE["jobs"].get(base.rsplit("/", 1)[1])
        return (200, _view(job)) if job else (404, dict(detail="job not found"))
    if base in ("/api/local-models/download/pause", "/api/local-models/download/resume") and method == "POST":
        job = STATE["jobs"].get(fields.get("job_id"))
        if job is None:
            return 404, dict(detail="unknown download job")
        view = _view(job)
        if base.endswith("/pause"):
            if not view["can_pause"]:
                return 200, dict(ok=True, paused=False)
            job.update(status="paused", paused_at=time.time())
            if job["scenario"] == "downloading":
                job["scenario"] = "paused"
            return 200, dict(ok=True, paused=True)
        if job["status"] != "paused" and job["scenario"] != "paused":
            return 200, dict(ok=True, resumed=False)
        if job["scenario"] == "paused":
            # Carry on from where it stopped, at the flow's pace.
            job.update(scenario="flow", started_at=time.time() - _progress(job) * FLOW_SECONDS, paused_seconds=0.0)
        elif job["paused_at"]:
            job["paused_seconds"] += time.time() - job["paused_at"]
        job.update(status="running", paused_at=None)
        return 200, dict(ok=True, resumed=True)
    if base == "/api/nollie/local-model/reply-check" and method == "POST":
        if not STATE["selected"]:
            return 503, dict(detail="The local model reply was not verified")
        return 200, dict(provider="llamacpp", model=STATE["selected"], text=REPLY)
    return 404, dict(detail="Not found")
