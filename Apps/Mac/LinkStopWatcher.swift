#if NOLLIE_DIRECT
import Foundation
import NollieCore
import UserNotifications

/// "Stop Nollie on my Mac" from a linked iPhone. The press reaches the Link door in Nollie Runtime,
/// which only records it; the app reads that record and does the stopping here (MacStop): a task
/// using this Mac ends, every reply in progress stops and schedules pause until the person resumes them.
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
        await perform(device: stop.device, key: "\(stop.generation)")
    }

    /// Stops everything through MacStop, then says so on the Mac. The same for a Stop through the
    /// door and one through iCloud. Returns schedules paused.
    @discardableResult
    func perform(device: String, key: String) async -> Int {
        let paused = await MacStop.stopEverything(.phone)
        tell(device: device, key: key, paused: paused)
        return paused
    }

    private func tell(device: String, key: String, paused: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Stopped from \(device)"
        content.body = Self.summary(paused: paused)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nollie.link.stop.\(key)", content: content, trigger: nil))
    }

    nonisolated static func summary(paused: Int) -> String { MacStop.summary(paused: paused) }
}
#endif
