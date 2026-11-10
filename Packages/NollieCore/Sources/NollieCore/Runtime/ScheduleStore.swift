import Foundation

/// Follows which schedules are running on the gateway, so a run the Mac's scheduler started shows
/// as its helper at work on every device, and gives the one Stop for a run.
///
/// Gently: one jobs list for every bot when Hermes says the schedules changed (`cron.changed`), and
/// otherwise once a minute, or every 15 seconds while something runs. Nothing is asked while the
/// app is in the background, and the watch ends for good on a gateway without schedules or one
/// that refuses this device the list.
@MainActor
@Observable
public final class ScheduleStore {
    public private(set) var activity = ScheduleActivity()
    /// Runs Stop was pressed for, until the gateway no longer lists them.
    public private(set) var stopping: Set<String> = []
    /// How often the list was read. Tests count it.
    public private(set) var reads = 0

    static let idleEvery: Duration = .seconds(60)
    static let busyEvery: Duration = .seconds(15)

    private(set) weak var runtime: GatewayRuntime?
    private var loop: Task<Void, Never>?
    private var soon: Task<Void, Never>?
    private var epoch = UUID()

    public init() {}

    func attach(_ runtime: GatewayRuntime) { self.runtime = runtime }

    public var isFollowing: Bool { loop != nil }

    /// Starts the watch, once.
    public func follow() {
        guard loop == nil, runtime != nil else { return }
        let mine = epoch
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.epoch == mine, await self?.look() == true, !Task.isCancelled else {
                    self?.end(mine)
                    return
                }
                let wait = self?.activity.runs.isEmpty != false ? Self.idleEvery : Self.busyEvery
                do { try await Task.sleep(for: wait) } catch { return }
            }
        }
    }

    /// Ends the watch and forgets what it saw.
    public func stop() {
        epoch = UUID()
        loop?.cancel(); loop = nil
        soon?.cancel(); soon = nil
        activity = ScheduleActivity()
        stopping = []
    }

    private func end(_ mine: UUID) {
        guard epoch == mine else { return }
        loop = nil
    }

    /// A look a moment from now: the schedules changed, the app came back, or Stop was pressed.
    /// Several asks close together share one look.
    public func lookSoon(after delay: Duration = .milliseconds(800)) {
        guard loop != nil else { return }
        soon?.cancel()
        soon = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            _ = await self?.look()
        }
    }

    /// One look. False when the gateway has no schedules for this device, so the watch stops.
    @discardableResult
    func look() async -> Bool {
        guard let runtime else { return false }
        if runtime.isAway { return true }
        let mine = epoch
        reads += 1
        do {
            let reply: JSONValue = try await runtime.api.get("/api/cron/jobs")
            guard epoch == mine else { return true }
            show(ScheduleActivity.read(reply, connection: runtime.connection.id))
            return true
        } catch HermesAPIError.http(let status, _) where [403, 404].contains(status) {
            if epoch == mine { activity = ScheduleActivity() }
            return false
        } catch {
            // A missed look leaves the last one, which goes stale by itself.
            return true
        }
    }

    func show(_ seen: ScheduleActivity) {
        let live = Set(seen.runs.map(\.jobID))
        stopping.formIntersection(live)
        if seen != activity { activity = seen }
    }

    // MARK: Stop

    /// Stops the job's run in flight (`POST /api/cron/jobs/{id}/cancel`). The schedule stays as it
    /// was; only this one run ends, at its next check. Throws when the gateway refuses or doesn't answer.
    public func cancel(job jobID: String, profile: String?) async throws -> ScheduleCancel {
        guard let runtime else { throw HermesAPIError.transport(String(localized: "No gateway", table: "Core")) }
        let path = "/api/cron/jobs/\(jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobID)/cancel"
        let reply: JSONValue = try await runtime.api.send("POST", path, profile: profile, body: EmptyBody())
        guard let answer = ScheduleCancel(reply) else { throw HermesAPIError.decoding(String(localized: "No answer to Stop", table: "Core")) }
        if answer.cancelled {
            stopping.insert(jobID)
        } else {
            // Nothing was in flight: it finished on its own, so it goes from the list now.
            show(ScheduleActivity(runs: activity.runs.filter { $0.jobID != jobID }, checkedAt: activity.checkedAt))
        }
        lookSoon(after: .seconds(2))
        return answer
    }
}
