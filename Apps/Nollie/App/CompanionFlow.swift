import Foundation
import NollieCore

/// Decides the moment the Companion offer shows once the first gateway has been saved, and what
/// each of its buttons does. It is offered a single time and waits whenever something else needs the person.
@MainActor @Observable
final class CompanionFlow {
    static let shownKey = "companionPromptShown"
    static let setupCardDoneKey = "notificationsSetupCardDone"

    var showsPrompt = false
    var showsInstaller = false
    /// The version of a Companion the gateway already runs. With one there, the prompt only asks
    /// for notification permission.
    private(set) var version: String?

    /// True from the first save until the prompt has come up.
    private var owed = false

    private var wasShown: Bool {
        get { (UserDefaults.standard.object(forKey: Self.shownKey) as? Bool) ?? false }
        set { UserDefaults.standard.setValue(newValue, forKey: Self.shownKey) }
    }

    var isShowing: Bool { showsPrompt || showsInstaller }

    func firstGatewaySaved() {
        owed = !wasShown
    }

    /// Shows the prompt once it is owed and `busy` is false (onboarding, a sign-in, the lock or a
    /// pairing would all be in the way).
    func offerIfFree(model: AppModel, busy: Bool) {
        guard owed, !wasShown, !busy, model.hasConnections, NotificationAskPause.mayAsk() else { return }
        (owed, wasShown) = (false, true)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            // A gateway that was set up on another device may already have the Companion running.
            if let runtime = model.runtime {
                version = await CompanionPromptSheet.installedVersion(on: runtime)
            }
            if model.lock.isLocked || model.pendingDevicePairing != nil || model.devicePairingFlowActive {
                (owed, wasShown) = (true, false)
            } else {
                showsPrompt = true
            }
        }
    }

    private func closePrompt(setupCardDone: Bool) {
        UserDefaults.standard.set(setupCardDone, forKey: Self.setupCardDoneKey)
        showsPrompt = false
    }

    /// Set up from here, so Settings need not suggest it.
    func chooseSetUp() {
        closePrompt(setupCardDone: true)
        showsInstaller = true
    }

    /// Allow: the token comes in, the device file is uploaded, and the Companion starts sending here.
    func chooseAllow(model: AppModel) {
        closePrompt(setupCardDone: true)
        Task { _ = await model.push.requestAuthorization() }
    }

    func chooseLater() {
        closePrompt(setupCardDone: false)
    }
}

/// Setup offers notifications on a step of its own (the Mac's Allow a few things, the iPhone's Ready). Someone who
/// was just offered them there is not asked again by the Stay in the loop sheet for a few days, whatever they chose.
enum NotificationAskPause {
    static let offeredKey = "nollie.setup.notificationsOfferedAt"
    static let pause: TimeInterval = 3 * 86_400

    /// Setup has just shown its notifications row.
    static func noteOffered(now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: offeredKey)
    }

    static func mayAsk(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        mayAsk(now: now, offeredAt: defaults.object(forKey: offeredKey) as? Date)
    }

    /// Never offered in setup, or offered at least a few days ago.
    static func mayAsk(now: Date, offeredAt: Date?) -> Bool {
        guard let offeredAt else { return true }
        return now.timeIntervalSince(offeredAt) >= pause
    }
}
