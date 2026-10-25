#if NOLLIE_DIRECT
import AppKit
import NollieCore

/// Switches the Nollie Computer pieces on when the app starts and off when it quits. Nothing acts on
/// the Mac until a person approves a task; this only opens the door the Hermes add-on knocks on.
@MainActor
enum MacComputerStartup {
    static func begin() {
        let center = ComputerCenter.shared
        center.presenter = ComputerPanels.shared
        center.announceStart = announceToPhone
        if ComputerHelper.isBundled { ComputerBroker.shared.start() }
        LinkStopWatcher.shared.start()
        // Live pictures: this Mac's own Watch screen plays its host in-process, and a linked
        // phone's go through Nollie Runtime.
        LiveHostCenter.install()
        LiveRelayClient.shared.start()
        #if DEBUG
        previewFromLaunchFlag(on: center)
        #endif
    }

    static func end() {
        ComputerCenter.shared.stop()
        ComputerBroker.shared.stop()
        LiveHostCenter.shared.stopAll()
    }

    /// A task the phone did not start is announced there, with a Stop on the alert.
    private static func announceToPhone(_ task: ComputerTask) {
        guard let connection = AppModel.shared.runtime?.connection else { return }
        Task {
            await CloudAlertTransport.shared.publishComputerStarted(
                profile: task.profile, botName: task.botName, sessionID: task.sessionID,
                startedAt: task.startedAt, connection: connection)
        }
    }

    #if DEBUG
    private static func previewFromLaunchFlag(on center: ComputerCenter) {
        let words = ProcessInfo.processInfo.arguments
        guard let at = words.firstIndex(of: "-nollie-computer-preview"), at + 1 < words.count else { return }
        center.showPreview(words[at + 1])
    }
    #endif
}
#endif
