import UserNotifications
import NollieCore
import AppKit

/// The Mac's app delegate. It starts the pieces that run with the app and passes notification and
/// push callbacks on to `MacNotificationDesk` and the model.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Started once the app is up, in this order.
    private static let services: [@MainActor () -> Void] = [
        { ContinuityMenuFilter.start() }, // Continuity Camera is limited to places a photo can be dropped
        { MacSleepAway.shared.start() },         // sleep and wake are this Mac's away and back
        { MacKeepAwake.shared.start() },         // stays awake for the crew, when that is on
        { SignInCenter.shared.start() },         // saved sign-ins for the add-on
        { AppleDataCenter.shared.start() },      // helpers' Calendar, Reminders and Contacts requests
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        LocalNotifier.registerCategories()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            for start in Self.services { start() }
            #if NOLLIE_DIRECT
            MacComputerStartup.begin()
            #endif
        }
    }

    #if NOLLIE_DIRECT
    func applicationWillTerminate(_ notification: Notification) {
        // The helper would exit anyway when its stdin closes. This stops it on purpose, first.
        MainActor.assumeIsolated { MacComputerStartup.end() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let running = ComputerCenter.shared.task else { return nil }
        let stop = NSMenuItem(title: "Stop \(running.botName) Using Your Mac",
                              action: #selector(stopUsingMac), keyEquivalent: "")
        stop.target = self
        let menu = NSMenu()
        menu.addItem(stop)
        return menu
    }

    @objc private func stopUsingMac() { ComputerCenter.shared.stop() }
    #endif
}

// MARK: Push registration

extension MacAppDelegate {
    @MainActor static var model: AppModel? { AppModel.shared }

    /// The system's answer to asking for a push token, passed to the model and the transport together.
    private func registered(_ outcome: Result<Data, Error>) {
        Task { @MainActor in
            let transport = CloudAlertTransport.shared
            switch outcome {
            case .success(let token):
                Self.model?.push.didRegister(token: token)
                transport.remoteRegistrationSucceeded()
            case .failure(let error):
                Self.model?.push.didFailToRegister(error)
                transport.remoteRegistrationFailed()
            }
        }
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        MacNotificationDesk.noteRemote(userInfo)
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        registered(.failure(error))
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registered(.success(deviceToken))
    }
}

// MARK: Notifications

extension MacAppDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { MacNotificationDesk.open(response) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MacNotificationDesk.presentation(for: notification)
    }
}
