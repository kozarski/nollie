import Foundation
import Observation

/// Drives the dashboard's two maintenance actions, "update Hermes" and "restart the gateway", and
/// tracks each until done through `/api/actions/{name}/status`. A gateway has just one of these, so
/// the banner on the chat list and the Companion's restart button always display one and the same run.
@MainActor
@Observable
public final class MaintenanceModel {
    public enum Phase: Equatable {
        case idle
        case running(String)
        case finished(String, exitCode: Int?)
        case failed(String)
    }

    /// Recognises the dashboard's complaint that it has newer code than the running process; that
    /// is a prompt to restart, not an actual failure.
    public nonisolated static func isRestartRequired(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.localizedCaseInsensitiveContains("Restart required")
    }

    public var phase: Phase = .idle
    /// The last lines of the action's log, while it runs and after it ends.
    public var actionLog: [String] = []

    private var watcher: Task<Void, Never>?

    public var isBusy: Bool { phase.isRunning }

    // MARK: What can be run

    /// One of the dashboard's actions, described by the routes and words it uses.
    private struct Job {
        /// The dashboard's name for the action, which its status route is filed under.
        let name: String
        let label: String
        let endpoint: String
        /// How long to wait for the action to report back. A restart goes through the very
        /// dashboard that is going down, so its status often never arrives.
        let patience: TimeInterval
        let profile: String?

        static func updateHermes(profile: String?) -> Job {
            Job(name: "hermes-update", label: String(localized: "Updating Hermes", table: "Core"), endpoint: "/api/hermes/update",
                patience: 15 * 60, profile: profile)
        }

        static func restartGateway(profile: String?) -> Job {
            Job(name: "gateway-restart", label: String(localized: "Restarting gateway", table: "Core"), endpoint: "/api/gateway/restart",
                patience: 2 * 60, profile: profile)
        }

        var statusPath: String { "/api/actions/\(name)/status" }
    }

    // MARK: Starting actions

    public func update(runtime: GatewayRuntime) async {
        await run(.updateHermes(profile: runtime.selectedProfile), on: runtime)
    }

    public func restartGateway(runtime: GatewayRuntime) async {
        await restartGateway(runtime: runtime, profile: runtime.selectedProfile)
    }

    /// Restarts the gateway of one profile (nil is the default profile's), which needn't be the
    /// bot selected in the app.
    public func restartGateway(runtime: GatewayRuntime, profile: String?) async {
        await run(.restartGateway(profile: profile), on: runtime)
    }

    /// Ends a running action with a verdict from outside, say because the gateway was seen
    /// answering again. Does nothing when nothing is running.
    public func finishEarly(_ message: String) {
        guard isBusy else { return }
        stopWatching()
        phase = .finished(message, exitCode: nil)
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: Running one

    private func run(_ job: Job, on runtime: GatewayRuntime) async {
        if isBusy { return }
        stopWatching()
        actionLog.removeAll()
        phase = .running(job.label)

        if let complaint = await kickOff(job, on: runtime) {
            phase = .failed(complaint)
            return
        }
        let task = Task { await follow(job, on: runtime) }
        watcher = task
        await task.value
    }

    /// Asks the dashboard to start the action. Returns what went wrong, or nil when it started.
    private func kickOff(_ job: Job, on runtime: GatewayRuntime) async -> String? {
        do {
            let reply: JSONValue = try await runtime.api.send("POST", job.endpoint, profile: job.profile, body: EmptyBody())
            guard reply["ok"]?.boolValue == false else { return nil }
            let words = [reply["message"], reply["error"]].compactMap { $0?.stringValue }.first
            return words ?? String(localized: "The gateway turned that action down.", table: "Core")
        } catch {
            return error.localizedDescription
        }
    }

    /// What the dashboard says about an action right now.
    private struct Report {
        let lines: [String]
        let isRunning: Bool
        let exitCode: Int?
        let outcome: String?

        init(_ raw: JSONValue) {
            lines = (raw["lines"]?.arrayValue ?? []).map(\.displayText)
            isRunning = raw["running"]?.boolValue ?? false
            exitCode = raw["exit_code"]?.intValue
            outcome = raw["receipt"]?["outcome"]?.stringValue
        }

        /// The closing words once it has ended, with `seenRunning` saying whether we ever saw
        /// it go. Nil means it hasn't ended, or we can't tell yet.
        func verdict(seenRunning: Bool) -> String? {
            if isRunning { return nil }
            let done = String(localized: "done", table: "Core", comment: "An update or restart finished, as in: Updating Hermes: done")
            if let outcome { return outcome == "success" ? done : outcome }
            if exitCode == nil && !seenRunning { return nil }
            if exitCode == 0 { return done }
            let code = exitCode.map(String.init) ?? "?"
            return String(localized: "exited \(code)", table: "Core", comment: "A program ended with this exit code, as in: Updating Hermes: exited 1")
        }
    }

    private func readReport(_ job: Job, runtime: GatewayRuntime) async -> Report? {
        let raw: JSONValue? = try? await runtime.api.get(job.statusPath,
                                                         query: [URLQueryItem(name: "lines", value: "60")],
                                                         profile: runtime.selectedProfile)
        return raw.map(Report.init)
    }

    /// Polls every two seconds until the action exits or patience runs out. Updating restarts
    /// the dashboard part way, so a failed poll means "it is restarting", not "it failed".
    private func follow(_ job: Job, on runtime: GatewayRuntime) async {
        let deadline = Date.now + job.patience
        var seenRunning = false

        while !Task.isCancelled && Date.now < deadline {
            try? await Task.sleep(for: .seconds(2))

            guard let report = await readReport(job, runtime: runtime) else {
                phase = .running(String(localized: "\(job.label): dashboard restarting…", table: "Core", comment: "The value is an action, such as Updating Hermes"))
                continue
            }
            actionLog = report.lines
            seenRunning = seenRunning || report.isRunning

            if let verdict = report.verdict(seenRunning: seenRunning) {
                phase = .finished(String(localized: "\(job.label): \(verdict)", table: "Core", comment: "An action, then how it ended: Updating Hermes: done"), exitCode: report.exitCode)
                await runtime.reconnectNow()
                return
            }
            // Still going, or the dashboard restarted before we saw the action run and
            // forgot it. Either way, keep waiting.
            phase = .running(report.isRunning ? job.label
                : String(localized: "\(job.label): waiting for the dashboard to come back", table: "Core", comment: "The value is an action, such as Updating Hermes"))
        }

        if isBusy {
            phase = .failed(String(localized: "\(job.label) never said it was done. Take a look at the gateway machine.", table: "Core", comment: "The value is an action, such as Updating Hermes"))
        }
    }
}

private extension MaintenanceModel.Phase {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
