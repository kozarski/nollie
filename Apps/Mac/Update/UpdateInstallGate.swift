#if NOLLIE_DIRECT
import Foundation

/// A turn that an update would cut short: a bot working on this Mac's own background service.
struct UpdateTurn: Hashable, Sendable {
    var id: String
    var bot: String
}

/// What the update gate needs from the running app. The real one reads the chats and the Mac
/// computer; tests use a fake.
@MainActor
protocol UpdateInstallEnvironment: AnyObject {
    /// Turns running now on the gateway that Nollie Runtime serves. Turns on any other gateway keep
    /// going whatever the Mac app does, so they are not listed.
    func runningTurns() -> [UpdateTurn]
    /// Stops a bot using this Mac, if one is. Returns whether anything was stopped.
    func stopComputer() -> Bool
    /// Interrupts one turn and leaves a note in its chat that Nollie paused it to update.
    func pause(_ turn: UpdateTurn) async
}

/// What the gate did, for the log.
struct UpdateInstallReport: Equatable {
    var computerStopped = false
    var finishedOnTheirOwn = 0
    var paused: [UpdateTurn] = []
}

/// Runs between "the update is ready" and "Nollie quits to install it", so the update never lands on
/// work in the middle. A bot using the Mac is stopped at once. Turns on Nollie's own background
/// service are given time to finish, because that service restarts on the new version right after
/// the install; any still going after that are paused, each with a note in its chat.
@MainActor
final class UpdateInstallGate {
    struct Timing: Equatable {
        /// How long a running turn may keep going before it is paused.
        var patience: Duration = .seconds(60)
        /// How often to look.
        var poll: Duration = .milliseconds(500)
        /// A short wait after pausing, so the gateway has the interrupt before Nollie quits.
        var settle: Duration = .seconds(3)
    }

    private let environment: any UpdateInstallEnvironment
    private let timing: Timing
    private let sleep: @MainActor (Duration) async -> Void
    private var inFlight: Task<UpdateInstallReport, Never>?

    var isPreparing: Bool { inFlight != nil }

    init(environment: any UpdateInstallEnvironment, timing: Timing = Timing(),
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.environment = environment
        self.timing = timing
        self.sleep = sleep
    }

    /// Gets the Mac ready for the install. Asking again while it is under way waits for the same run.
    func prepare() async -> UpdateInstallReport {
        if let inFlight { return await inFlight.value }
        let run = Task { await self.run() }
        inFlight = run
        let report = await run.value
        inFlight = nil
        return report
    }

    private func run() async -> UpdateInstallReport {
        var report = UpdateInstallReport()
        report.computerStopped = environment.stopComputer()

        let before = environment.runningTurns()
        guard !before.isEmpty else { return report }

        var waited = Duration.zero
        while waited < timing.patience, !Task.isCancelled, !environment.runningTurns().isEmpty {
            await sleep(timing.poll)
            waited += timing.poll
        }

        let remaining = environment.runningTurns()
        let stillGoing = Set(remaining)
        report.finishedOnTheirOwn = before.filter { !stillGoing.contains($0) }.count
        for turn in remaining {
            await environment.pause(turn)
            report.paused.append(turn)
        }
        if !remaining.isEmpty { await sleep(timing.settle) }
        return report
    }
}
#endif
