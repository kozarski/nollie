import Foundation
import NollieCore

/// How a scheduled task is shown. Everything here reads the gateway's own scheduler record; the
/// app keeps no task store of its own.
enum ScheduledWork {
    /// Whether a change started for `expected` may still be applied: the app is unlocked, the
    /// work was not cancelled, and the same gateway is still the one in use.
    static func allows(expected: AnyObject, current: AnyObject?, locked: Bool, cancelled: Bool) -> Bool {
        guard !locked, !cancelled else { return false }
        return current === expected
    }

    /// The bot a job belongs to.
    static func owner(_ raw: JSONValue) -> String? {
        raw["profile"]?.stringValue ?? raw["profile_name"]?.stringValue
    }

    static func failureMessage(_ error: Error) -> String {
        switch error {
        case HermesAPIError.sessionExpired:
            return String(localized: "Sign in again, then reopen Schedules.")
        case HermesAPIError.http(let code, _) where code == 401 || code == 403:
            return String(localized: "This change is not allowed. Check your connection and sign-in, then reopen Schedules.")
        default:
            return String(localized: "Your assistant did not confirm the change. Reopen Schedules and check the task before trying again.")
        }
    }

    /// A job from the gateway's JSON, or nil when it has no id.
    static func decode(_ raw: JSONValue) -> CronJob? {
        let id = raw["id"]?.stringValue
        let jobId = raw["job_id"]?.stringValue
        guard id != nil || jobId != nil else { return nil }
        var job = CronJob(
            id: id, jobId: jobId,
            name: raw["name"]?.stringValue,
            schedule: CronSchedule.expression(of: raw["schedule"]),
            prompt: raw["prompt"]?.stringValue,
            promptPreview: raw["prompt_preview"]?.stringValue,
            enabled: raw["enabled"]?.boolValue,
            state: raw["state"]?.stringValue,
            nextRunAt: raw["next_run_at"]?.stringValue,
            lastRunAt: raw["last_run_at"]?.stringValue,
            lastStatus: raw["last_status"]?.stringValue)
        job.deliver = raw["deliver"]?.stringValue
        return job
    }

    static func paused(_ job: CronJob) -> Bool {
        job.enabled == false || job.state == "paused"
    }

    static func completed(_ job: CronJob) -> Bool {
        guard let state = job.state else { return false }
        return ["completed", "finished", "done"].contains(state)
    }

    /// One word for the job's standing, shown in the list.
    static func status(_ job: CronJob, raw: JSONValue) -> String {
        if CronRun.isRunning(raw) { return String(localized: "Checking now", comment: "A scheduled task's standing") }
        if completed(job) { return String(localized: "Finished", comment: "A scheduled task's standing") }
        if paused(job) { return String(localized: "Paused", comment: "A scheduled task's standing") }
        if let last = job.lastStatus, last != "skipped", !CronRun.isGood(last) {
            return String(localized: "Check needed", comment: "A scheduled task's standing")
        }
        return String(localized: "Scheduled", comment: "A scheduled task's standing")
    }

    static func next(_ job: CronJob) -> String {
        if completed(job) { return String(localized: "No more checks") }
        if paused(job) { return String(localized: "Paused", comment: "A scheduled task's standing") }
        return date(job.nextRunAt) ?? String(localized: "Not yet reported")
    }

    /// A timestamp as a short date and time, or nil when it cannot be read.
    static func date(_ value: String?) -> String? {
        guard let value, let parsed = CronSchedule.onceDate(value) else { return nil }
        return parsed.formatted(date: .abbreviated, time: .shortened)
    }

    /// The last run, when it started late: when it was due and when it ran, from Hermes's `last_dispatch`. Nil for
    /// a run on time, for Run now (Hermes records no dispatch for it) and for a record older than the last run.
    static func lateRun(_ raw: JSONValue) -> (due: Date, ran: Date)? {
        let dispatch = raw["last_dispatch"]
        guard ["late", "catch_up"].contains(dispatch?["kind"]?.stringValue ?? ""),
              let due = dispatch?["scheduled_at"]?.stringValue.flatMap(CronSchedule.onceDate),
              let sent = dispatch?["dispatched_at"]?.stringValue.flatMap(CronSchedule.onceDate),
              let ran = raw["last_run_at"]?.stringValue.flatMap(CronSchedule.onceDate),
              sent.timeIntervalSince(due) > SleepNote.lateSeconds,
              sent <= ran.addingTimeInterval(60), ran.timeIntervalSince(sent) < 3 * 3600 else { return nil }
        return (due, sent)
    }

    static func result(_ job: CronJob) -> String {
        guard let status = job.lastStatus, !status.isEmpty else { return String(localized: "No result yet") }
        if CronRun.isGood(status) { return String(localized: "Completed", comment: "A scheduled task's last result") }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Whether a reply really describes the job `jobID`, optionally in the expected enabled state
    /// and for the expected bot.
    static func confirms(_ response: JSONValue, jobID: String, enabled: Bool? = nil, profile: String? = nil) -> Bool {
        guard let job = decode(response), job.identity == jobID else { return false }
        if let profile, owner(response) != profile { return false }
        switch enabled {
        case nil: return true
        case true?: return job.enabled == true && job.state != "paused"
        case false?: return job.enabled == false || job.state == "paused"
        }
    }
}
