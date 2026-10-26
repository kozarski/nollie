#if NOLLIE_DIRECT
import Foundation
import NollieCore
import UserNotifications

/// "Stop Nollie on my Mac" from a linked iPhone. The press reaches the Link door in Nollie Runtime,
/// which only records it; the app reads that record and does the stopping here: a task using this
/// Mac ends, every reply in progress stops and schedules pause until the person resumes them.
@MainActor
final class LinkStopWatcher {
    static let shared = LinkStopWatcher()
    private var seen: Int?
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let wait = await self?.check() ?? 10
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Seconds until the next look: often while a phone is linked, rarely otherwise.
    private func check() async -> Double {
        guard NollieLinkMacClient.isAvailable(for: AppModel.shared.runtime?.connection),
              let status = try? await NollieLinkMacClient.status() else { return 10 }
        if let stop = status.stop, Self.isNew(stop.generation, after: seen) { await act(stop) }
        seen = status.stop?.generation ?? 0
        return status.devices.isEmpty ? 10 : 2
    }

    /// A Stop counts once. The first look only learns where the count is, and a helper restart
    /// starts the count again from one.
    nonisolated static func isNew(_ generation: Int, after seen: Int?) -> Bool {
        guard let seen else { return false }
        return generation > seen || (generation < seen && generation > 0)
    }

    private func act(_ stop: NollieLinkIPCStop) async {
        ComputerCenter.shared.end(.phone)
        guard let runtime = AppModel.shared.runtime else { tell(stop, paused: 0); return }
        for chat in runtime.chats where chat.isRunning { await chat.stop() }
        tell(stop, paused: await pauseSchedules(runtime))
    }

    /// Pauses every schedule that would start more work, and counts only the pauses Hermes
    /// confirms. A private bot's schedules are left alone.
    private func pauseSchedules(_ runtime: GatewayRuntime) async -> Int {
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

    private func tell(_ stop: NollieLinkIPCStop, paused: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Stopped from \(stop.device)"
        content.body = Self.summary(paused: paused)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nollie.link.stop.\(stop.generation)", content: content, trigger: nil))
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
