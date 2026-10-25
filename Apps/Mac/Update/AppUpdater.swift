#if NOLLIE_DIRECT
import Combine
import Foundation
import NollieCore
import Sparkle

/// Automatic updates for the Direct Mac edition, through Sparkle. The store edition does not have this
/// file's work at all: it is compiled out, and so is Sparkle.
///
/// Sparkle's own windows do the asking and the downloading. What Nollie adds is the care before the
/// install (`UpdateInstallGate`) and the two places a person controls it: Check for Updates in the app
/// menu and the switch in Settings > About.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// False in a build made before the release key exists. Nothing is checked then.
    let isConfigured: Bool
    private(set) var canCheck = false
    private(set) var automaticChecks = false
    private(set) var lastCheck: Date?

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private var watching = Set<AnyCancellable>()

    init(info: [String: Any]? = Bundle.main.infoDictionary,
         environment: any UpdateInstallEnvironment = LiveUpdateEnvironment()) {
        let configuration = SparkleConfiguration(info: info)
        isConfigured = configuration != nil
        hooks = Hooks(gate: UpdateInstallGate(environment: environment))
        guard configuration != nil else {
            controller = nil
            NollieLog.updates.notice("Updates are not set up in this build")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: hooks, userDriverDelegate: nil)
        if let updater = controller?.updater {
            automaticChecks = updater.automaticallyChecksForUpdates
            lastCheck = updater.lastUpdateCheckDate
            canCheck = updater.canCheckForUpdates
            updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheck = $0 }.store(in: &watching)
            updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.automaticChecks = $0 }.store(in: &watching)
            updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.lastCheck = $0 }.store(in: &watching)
        }
    }

    /// Check for Updates… in the menu and in Settings.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        automaticChecks = on
    }

    /// Sparkle calls these. `NSObject` is Sparkle's requirement, so they live apart from the model.
    final class Hooks: NSObject, SPUUpdaterDelegate {
        private let gate: UpdateInstallGate

        @MainActor init(gate: UpdateInstallGate) {
            self.gate = gate
        }

        /// Sparkle is about to quit Nollie to install. Wait for the gate, then let it go on.
        func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                     untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
            nonisolated(unsafe) let proceed = installHandler
            let gate = gate
            Task { @MainActor in
                let report = await gate.prepare()
                NollieLog.updates.notice("Ready to update",
                                         detail: "computer stopped \(report.computerStopped), finished \(report.finishedOnTheirOwn), paused \(report.paused.count)")
                proceed()
            }
            return true
        }

        func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
            NollieLog.updates.notice("Relaunching to finish the update")
        }

        func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
            let nsError = error as NSError
            // "No update found" is an answer, not a failure.
            if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return }
            NollieLog.updates.error("Update check did not finish", detail: nsError.localizedDescription)
        }
    }
}
#endif
