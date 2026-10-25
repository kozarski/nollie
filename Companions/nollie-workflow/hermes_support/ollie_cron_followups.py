"""Narrow atomic binding for the versioned native cron pre-check contract."""
from __future__ import annotations


def ready():
    from cron import scheduler
    return getattr(scheduler, "OLLIE_FAIL_CLOSED_PRECHECK_VERSION", None) == 1


def bind_gate(job_id, expected, script, signature):
    from cron import jobs
    if not ready():
        raise RuntimeError("native fail-closed pre-check support is not installed")

    def apply(records, index, raw):
        job = jobs._normalize_job_record(raw)
        if (job.get("id") != job_id or signature(job) != expected
                or job.get("enabled") is not False or job.get("state") != "paused"
                or job.get("script") not in (None, "", script)):
            raise ValueError("native job changed before binding")
        updated = dict(raw, script=script, precheck_fail_closed=True)
        records[index] = updated
        jobs.save_jobs(records)
        return jobs._normalize_job_record(updated)
    # _with_job owns the native cross-process job lock for read, compare and save.
    return jobs._with_job(job_id, apply)


def pause_gate(job_id, expected, script, signature, reason):
    from cron import jobs

    def apply(records, index, raw):
        job = jobs._normalize_job_record(raw)
        if signature(job) != expected or job.get("script") != script:
            return None
        updated = dict(raw, enabled=False, state="paused", paused_at=jobs._hermes_now().isoformat(), paused_reason=reason)
        updated.pop("pending_slot", None)
        records[index] = updated
        jobs.save_jobs(records)
        return jobs._normalize_job_record(updated)
    return jobs._with_job(job_id, apply)
