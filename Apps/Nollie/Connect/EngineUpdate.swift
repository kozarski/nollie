#if os(macOS)
import Foundation
import Observation

/// A newer Nollie can carry a newer Hermes. A setup that was ready on the older one moves to it by
/// itself at launch: Hermes stops, the reviewed engine and its libraries are prepared again, the
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

    /// The steps to prepare again: a setup prepared before, on a plan this Nollie no longer runs.
    /// Download manager and Python move separately; when either is not ready, the setup screen handles it.
    nonisolated static func stepsToRedo(verified: [String: Bool], hasReceipt: [String: Bool]) -> [String] {
        guard verified["uv"] == true, verified["python"] == true else { return [] }
        let engine = ["hermes", "dependencies", "addons"]
        guard engine.contains(where: { hasReceipt[$0] == true && verified[$0] != true }) else { return [] }
        // Each later step is checked against the earlier ones, so once one is redone the rest follow.
        guard let first = engine.firstIndex(where: { verified[$0] != true }) else { return [] }
        return Array(engine[first...])
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
