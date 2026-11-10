import Foundation
import NollieCore

/// Stop for one schedule's run, wherever it shows: the chat list's bar, a schedule's page, the Mac's
/// menu bar. Only that run ends; the schedule stays on and runs again at its next time, so there is
/// nothing to confirm. What it says comes from Hermes's reply.
enum ScheduleStopWords {
    static let stopLabel = String(localized: "Stop this run", comment: "Safety: ends one schedule's run in progress; the schedule stays")
    static let stopping = String(localized: "Stopping…", comment: "Safety: Stop was pressed for a schedule's run")
    static let stopped = String(localized: "Stopped. The schedule stays on.", comment: "Safety: Hermes is stopping the run")
    static let alreadyDone = String(localized: "It had already finished.", comment: "Safety: Stop found no run in progress")
    static let notStopped = String(localized: "Couldn't stop it. Try again.", comment: "Safety: Stop did not reach Hermes")
    static let hint = String(localized: "Ends this run. The schedule stays on.", comment: "Safety: what Stop on a schedule's run does")

    /// "Stop “Morning brief”", in a list of several helpers.
    static func stopNamed(_ name: String) -> String {
        String(localized: "Stop “\(name)”", comment: "Safety: ends one schedule's run in progress, named")
    }

    /// The words for Hermes's answer, or for no answer.
    static func words(for answer: ScheduleCancel?) -> String {
        guard let answer else { return notStopped }
        return answer.cancelled ? stopped : alreadyDone
    }

    /// Asks Hermes to stop the job's run and says how it went.
    @MainActor static func stop(jobID: String, profile: String?, on runtime: GatewayRuntime) async -> String {
        let answer = try? await runtime.schedules.cancel(job: jobID, profile: profile)
        return words(for: answer)
    }
}
