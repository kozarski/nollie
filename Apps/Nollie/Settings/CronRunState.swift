import Foundation
import NollieCore

/// What the "Run now" button on a scheduled task is doing, and what it says about it.
///
/// Hermes replies to a run request only after the task completes, so the old button sat there
/// unchanged for the whole run and got pressed again. Now a tap flips it to "Running…" at once and
/// holds it disabled until the gateway replies. After that it briefly says "Started" or
/// "Finished", or explains the problem simply.
struct CronRun: Equatable {
    enum Phase: Equatable {
        case idle
        /// Sent, and the gateway is on it.
        case running
        /// Accepted, but the answer named no current run or result.
        case requested
        /// Accepted, but never confirmed done: the reply stopped partway, and asking again shows the
        /// job mid-run.
        case started
        /// A complete reply; `result` is the status of its latest run.
        case finished(result: String?)
        case failed(String)
    }

    /// Seconds the "Started" or "Finished" label lingers before "Run now" returns.
    static let confirmationSeconds: Double = 3

    private(set) var attempt = 0
    private(set) var phase = Phase.idle

    /// Tapping is disabled during a run and during its confirmation, so the same task cannot
    /// be launched twice.
    var isBusy: Bool {
        if case .idle = phase { return false }
        if case .failed = phase { return false }
        return true
    }

    // MARK: Events

    /// A tap. Returns true when a run should be sent; never while one is already out.
    mutating func begin() -> Bool {
        guard !isBusy else { return false }
        phase = .running
        attempt &+= 1
        return true
    }

    /// Handles the gateway's reply. If the job's last run differs from `lastRunBefore` (captured at
    /// tap time), the reply is that run, completed.
    mutating func answered(_ reply: JSONValue?, lastRunBefore: String?, jobID: String) {
        guard case .running = phase else { return }
        phase = Self.outcome(of: reply, lastRunBefore: lastRunBefore, jobID: jobID) ?? .requested
    }

    /// What a job record says about the run that was asked for, if it is a record of that job.
    private static func outcome(of record: JSONValue?, lastRunBefore: String?, jobID: String) -> Phase? {
        guard let record, ScheduledWork.confirms(record, jobID: jobID) else { return nil }
        if ranSince(lastRunBefore, record) { return .finished(result: result(of: record)) }
        return isRunning(record) ? .started : nil
    }

    /// Handles a failed request. When no reply came at all (see `mayStillBeRunning`) the job is
    /// fetched again as `jobNow`: a task that runs longer than our wait is alive on the gateway, and
    /// reporting that as an error invited a second press.
    mutating func failed(_ error: Error, jobNow: JSONValue? = nil, lastRunBefore: String? = nil, jobID: String? = nil) {
        guard case .running = phase else { return }
        if error is CancellationError {
            phase = .idle
        } else if let failure = error as? HermesAPIError, case .decoding = failure {
            // Success, but unreadable: the gateway still accepted the run.
            phase = .requested
        } else if Self.mayStillBeRunning(after: error), let jobID,
                  let found = Self.outcome(of: jobNow, lastRunBefore: lastRunBefore, jobID: jobID) {
            phase = found
        } else {
            phase = .failed(Self.plainWords(error))
        }
    }

    /// Once "Started" or "Finished" has shown long enough, go back to "Run now" unless a newer run
    /// began meanwhile. A failure message sticks around until the person taps again.
    mutating func settle(attempt finished: Int) {
        guard finished == attempt, isBusy, phase != .running else { return }
        phase = .idle
    }

    // MARK: The button's appearance

    var title: String {
        switch phase {
        case .running: "Running…"
        case .started: "Started"
        case .requested: "Requested"
        case .finished: "Finished"
        case .idle, .failed: "Run now"
        }
    }

    /// Symbol for the button; nil while running, because a spinner sits there instead.
    var symbol: String? {
        switch phase {
        case .running:
            return nil
        case .requested:
            return "clock"
        case .started:
            return "checkmark.circle"
        case .finished(let result?) where !Self.isGood(result):
            return "exclamationmark.circle"
        case .finished:
            return "checkmark.circle"
        case .idle, .failed:
            return "play.circle"
        }
    }

    /// Caption under the button, with a flag marking it as a problem.
    var note: (text: String, isProblem: Bool)? {
        let calm: (String) -> (text: String, isProblem: Bool) = { ($0, false) }
        switch phase {
        case .idle:
            return nil
        case .failed(let message):
            return (message, true)
        case .running:
            return calm("Waiting for your assistant to confirm the result. Leaving this page does not cancel the request.")
        case .started:
            return calm("Your assistant is still checking. The last result updates when it finishes.")
        case .requested:
            return calm("Your request was sent. A finished result has not been confirmed yet.")
        case .finished(let result):
            return result.map { ("Last result: \($0).", !Self.isGood($0)) }
        }
    }

    // MARK: Interpreting replies

    /// Only worth querying the job when no reply came back whatsoever, since a long-running task may
    /// just be outlasting our patience.
    static func mayStillBeRunning(after error: Error) -> Bool {
        guard let failure = error as? HermesAPIError, case .transport = failure else { return false }
        return true
    }

    /// True when the job finished a run after `before` (its last run at the moment of the tap).
    static func ranSince(_ before: String?, _ job: JSONValue) -> Bool {
        guard !isRunning(job),
              let latest = job["last_run_at"]?.stringValue, !latest.isEmpty,
              let outcome = result(of: job),
              !["running", "claimed", "pending", "queued"].contains(outcome)
        else { return false }
        return latest != before
    }

    /// Whether a run is in progress: the gateway holds a claim on the job, or its latest
    /// execution is claimed or running, or the job's state says running.
    static func isRunning(_ job: JSONValue) -> Bool {
        let claimed = job["fire_claim"].map { !$0.isNull } ?? false
        let executing = ["claimed", "running"].contains(job["latest_execution"]?["status"]?.stringValue ?? "")
        return claimed || executing || job["state"]?.stringValue == "running"
    }

    /// Last status in plain words: "delivery_failed" becomes "delivery failed".
    static func result(of job: JSONValue) -> String? {
        job["last_status"]?.stringValue
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    private static let goodResults: Set<String> = ["ok", "success", "succeeded", "completed", "done"]

    static func isGood(_ result: String) -> Bool { goodResults.contains(result.lowercased()) }

    /// Turns a failure into words a person can act on.
    static func plainWords(_ error: Error) -> String {
        let unclear = "Your assistant could not confirm this check. Reopen Schedules before trying again."
        guard let failure = error as? HermesAPIError else { return unclear }
        switch failure {
        case .http(let code, _):
            switch code {
            // Hermes refuses a second run while one is live, whether it came from another tap, another
            // device or the schedule.
            case 409: return "This one is already running. Give it a moment, then try again."
            case 404: return "This task is gone from the gateway. Go back and refresh the list."
            default: return "Your assistant could not run this check (error \(code))."
            }
        case .transport:
            return "No answer from your assistant. Check the task before trying again."
        case .sessionExpired:
            return "Your sign-in has run out. Please sign in again."
        default:
            return unclear
        }
    }
}

/// Tracks runs still going, per gateway and task, while the app is open. Leave a task mid-run and
/// come back, and the button still reads "Running…" and still ignores taps.
@MainActor @Observable final class CronRuns {
    static let shared = CronRuns()
    private(set) var runs = [String: CronRun]()

    func run(_ key: String) -> CronRun {
        runs[key, default: CronRun()]
    }

    func update(_ key: String, _ change: (inout CronRun) -> Void) {
        change(&runs[key, default: CronRun()])
    }
}
