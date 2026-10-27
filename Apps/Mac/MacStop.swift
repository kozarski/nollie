#if os(macOS)
import Foundation
import NollieCore

/// Stop on the Mac: a task using this Mac ends, every reply in progress stops and schedules pause
/// until the person resumes them. One path for every Stop the Mac takes: from a linked iPhone
/// (LinkStopWatcher), and from Siri, Shortcuts, Spotlight and the Stop control here (StopMacIntent).
@MainActor
enum MacStop {
    /// Stop pressed on this Mac. Returns what Siri says.
    static func press() async -> String {
        summary(paused: await stopEverything(.stopped))
    }

    /// Ends the computer task for `reason`, stops the running replies and pauses the schedules.
    /// Returns how many schedules Hermes confirmed paused.
    static func stopEverything(_ reason: ComputerTask.End) async -> Int {
        ComputerCenter.shared.end(reason)
        guard let runtime = AppModel.shared.runtime else { return 0 }
        for chat in runtime.chats where chat.isRunning { await chat.stop() }
        return await pauseSchedules(runtime)
    }

    /// Pauses every schedule that would start more work, and counts only the pauses Hermes
    /// confirms. A private bot's schedules are left alone.
    private static func pauseSchedules(_ runtime: GatewayRuntime) async -> Int {
        guard let list: JSONValue = try? await runtime.api.get("/api/cron/jobs") else { return 0 }
        var paused = 0
        for raw in list["jobs"]?.arrayValue ?? list["items"]?.arrayValue ?? list.arrayValue ?? [] {
            guard let job = ScheduledWork.decode(raw), !ScheduledWork.paused(job), !ScheduledWork.completed(job) else { continue }
            let owner = ScheduledWork.owner(raw)
            if let owner, PrivateBots.isPrivate(owner, connection: runtime.connection.id) { continue }
            guard let reply: JSONValue = try? await runtime.api.send("POST", "/api/cron/jobs/\(job.identity)/pause", profile: owner, body: EmptyBody()),
                  ScheduledWork.confirms(reply, jobID: job.identity, enabled: false, profile: owner) else { continue }
            paused += 1
        }
        return paused
    }

    nonisolated static func summary(paused: Int) -> String {
        switch paused {
        case 0: "Nollie ended its task on this Mac and stopped its replies."
        case 1: "Nollie ended its task on this Mac, stopped its replies and paused 1 schedule. Resume it in Schedules."
        default: "Nollie ended its task on this Mac, stopped its replies and paused \(paused) schedules. Resume them in Schedules."
        }
    }
}
#endif
