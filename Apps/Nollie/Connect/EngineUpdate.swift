#if os(macOS)
import Foundation
import Observation

/// A newer Nollie can carry a newer Hermes, Python or download manager. A setup that was ready on the
/// older ones moves to them by itself at launch: Hermes stops, what changed is prepared again, the
/// add-ons follow, and the service starts again if it was running. Bots, chats, schedules and
/// settings live in the setup's home folder and are not touched.
@MainActor @Observable
final class EngineUpdate {
    enum Phase: Equatable { case idle, updating, done, failed }

    static let shared = EngineUpdate()
    private(set) var phase: Phase = .idle

    /// What the sidebar says while it runs, or nil.
    var note: String? {
        switch phase {
        case .updating: String(localized: "Updating Nollie's engine")
        case .failed: String(localized: "Engine update didn't finish")
        case .idle, .done: nil
        }
    }

    /// The steps to prepare again: a setup that was fully prepared once, on a plan this Nollie no longer runs
    /// (a newer download manager, Python or Hermes). Each step is checked against the ones before it, so from
    /// the first that's out of date every later one is run; a step already current is passed over by the
    /// installer. A setup never finished stays with the setup screen.
    nonisolated static func stepsToRedo(verified: [String: Bool], hasReceipt: [String: Bool]) -> [String] {
        let steps = ["uv", "python", "hermes", "dependencies", "addons"]
        guard steps.allSatisfy({ hasReceipt[$0] == true }) else { return [] }
        guard let first = steps.firstIndex(where: { verified[$0] != true }) else { return [] }
        return Array(steps[first...])
    }

    func runIfNeeded() async {
        guard phase == .idle, NativeSetupPlan.directAvailable, !DemoMode.isOn,
              let installation = MacHermesSetup.selectedInstallation(),
              let id = UUID(uuidString: installation.lastPathComponent) else { return }
        let installer = NativeDependencyInstaller(installation: installation)
        var verified: [String: Bool] = [:], receipts: [String: Bool] = [:]
        for step in NativeSetupPlan.preparationSteps {
            verified[step] = (try? await installer.verified(step)) == true
            receipts[step] = (try? NativeDependencyInstaller.readReceipt(installation: installation, id: step)) != nil
        }
        let steps = Self.stepsToRedo(verified: verified, hasReceipt: receipts)
        guard !steps.isEmpty else { return }
        phase = .updating
        let runtime = ManagedRuntimeClient()
        await runtime.refresh(installationID: id)
        let wasRunning = runtime.isRegistered
        guard await runtime.pauseForUpdate() else { phase = .failed; return }
        do {
            for step in steps { try await installer.install(step) }
        } catch {
            phase = .failed
            return
        }
        if wasRunning { await runtime.start(installationID: id) }
        phase = wasRunning && runtime.state != .ready ? .failed : .done
    }
}
#endif
