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
    /// An update that stopped part way (the app quit, the download dropped) has already moved its old
    /// receipts away, so `unfinished` lets it carry on from where it stopped the next time Nollie opens.
    nonisolated static func stepsToRedo(verified: [String: Bool], hasReceipt: [String: Bool], unfinished: Bool = false) -> [String] {
        let steps = ["uv", "python", "hermes", "dependencies", "addons"]
        guard unfinished || steps.allSatisfy({ hasReceipt[$0] == true }) else { return [] }
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
        let defaults = UserDefaults.standard
        let unfinished = defaults.string(forKey: Self.unfinishedKey) == id.uuidString
        let steps = Self.stepsToRedo(verified: verified, hasReceipt: receipts, unfinished: unfinished)
        guard !steps.isEmpty else {
            if unfinished { defaults.removeObject(forKey: Self.unfinishedKey) }
            return
        }
        phase = .updating
        let runtime = ManagedRuntimeClient()
        await runtime.refresh(installationID: id)
        let wasRunning = runtime.isRegistered
        defaults.set(id.uuidString, forKey: Self.unfinishedKey)
        guard await runtime.pauseForUpdate() else { phase = .failed; return }
        do {
            for step in steps { try await installer.install(step) }
        } catch {
            phase = .failed
            return
        }
        defaults.removeObject(forKey: Self.unfinishedKey)
        if wasRunning { await runtime.start(installationID: id) }
        phase = wasRunning && runtime.state != .ready ? .failed : .done
    }

    /// The setup whose update has started and not finished yet.
    static let unfinishedKey = "nollie.engineUpdate.unfinished.v1"

    /// Whether to start Hermes again at launch: the background service is still on, Hermes is stopped, and
    /// every part of the setup checks out. Turning the service off in Settings removes it, so a service
    /// that is on with Hermes stopped only means something paused it and never brought it back.
    nonisolated static func shouldResume(serviceOn: Bool, hermesStopped: Bool, verified: [String: Bool]) -> Bool {
        serviceOn && hermesStopped && ["uv", "python", "hermes", "dependencies", "addons"].allSatisfy { verified[$0] == true }
    }

    /// Runs after the engine and add-on updates at launch.
    func resumeIfStopped() async {
        guard phase != .updating, NativeSetupPlan.directAvailable, !DemoMode.isOn,
              let installation = MacHermesSetup.selectedInstallation(),
              let id = UUID(uuidString: installation.lastPathComponent) else { return }
        let runtime = ManagedRuntimeClient()
        await runtime.refresh(installationID: id)
        guard runtime.state == .stopped else { return }
        let installer = NativeDependencyInstaller(installation: installation)
        var verified: [String: Bool] = [:]
        for step in NativeSetupPlan.preparationSteps { verified[step] = (try? await installer.verified(step)) == true }
        guard Self.shouldResume(serviceOn: runtime.isRegistered, hermesStopped: true, verified: verified) else { return }
        await runtime.start(installationID: id)
        if phase == .failed, runtime.state == .ready { phase = .done }
    }
}
#endif
