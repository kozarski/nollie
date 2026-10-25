#if os(iOS)
import UIKit
import UserNotifications
import NollieCore

/// The UIKit delegate for push registration and notification taps. (The Mac has `MacAppDelegate`.)
/// The work itself sits in `AlertArrivals` below; each method here only hands over.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        ChatGoals.shared.useTestWriterIfAsked()
        #endif
        UNUserNotificationCenter.current().delegate = self
        LocalNotifier.registerCategories()
        // The notification extensions learn each bot's look from the very first launch.
        BotLooksMirror.mirror()
        #if DEBUG
        askForNotificationsIfTold()
        #endif
        return true
    }

    #if DEBUG
    /// On a simulator, `simctl push` only works after the app has requested permission.
    private func askForNotificationsIfTold() {
        guard CommandLine.arguments.contains("-nollie-request-notifications") else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }
    #endif

    static var model: AppModel? { AppModel.shared }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { AlertArrivals.registered(with: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { AlertArrivals.registrationFailed(error) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let fresh = await AlertArrivals.silentPush(userInfo)
            completionHandler(fresh ? .newData : .noData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        Task { completionHandler(await AlertArrivals.presentation(for: info)) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task {
            await AlertArrivals.answer(response, center: center)
            completionHandler()
        }
    }
}

/// What happens when an alert registers, arrives or is tapped. The delegate runs on the main
/// actor, so everything here does too.
@MainActor
private enum AlertArrivals {
    private static var model: AppModel? { AppDelegate.model }

    // MARK: Registering

    static func registered(with token: Data) {
        model?.push.didRegister(token: token)
        CloudAlertTransport.shared.remoteRegistrationSucceeded()
    }

    static func registrationFailed(_ error: Error) {
        model?.push.didFailToRegister(error)
        CloudAlertTransport.shared.remoteRegistrationFailed()
    }

    /// A silent push from the cloud relay. True when it brought something new.
    static func silentPush(_ info: [AnyHashable: Any]) async -> Bool {
        let seen = CloudAlertTransport.inspectPayload(info)
        CloudAlertTransport.shared.recordCallback(.remote, result: seen.result)
        guard let eventID = seen.eventID else { return false }
        return await CloudAlertTransport.shared.recordReceipt(eventID: eventID, opened: false)
    }

    // MARK: Arriving while the app is open

    static func presentation(for info: [AnyHashable: Any]) async -> UNNotificationPresentationOptions {
        let seen = CloudAlertTransport.inspectPayload(info)
        CloudAlertTransport.shared.recordCallback(.foreground, result: seen.result)

        if let eventID = seen.eventID {
            Task { await CloudAlertTransport.shared.recordReceipt(eventID: eventID, opened: false) }
            let event = await ForegroundNotificationLookup.resolve {
                await CloudAlertTransport.shared.foregroundEvent(eventID: eventID)
            }
            return ForegroundNotificationPolicy.options(event: event, context: ForegroundNotificationPolicy.context(model))
        }
        // The outcome of Stop from an alert has no screen of its own, so it shows even in the app.
        if info["nollie"] as? String == "stopResult" { return [.banner, .list] }

        // The push setup test looks for these: that any push arrived, and that one carrying a nonce
        // was also decrypted.
        let hermes = info["hermes"] as? [String: Any]
        PushSetupModel.lastPresentedAt = Date()
        if let nonce = hermes?["nonce"] as? String { PushSetupModel.presentedNonces.insert(nonce) }
        return ForegroundNotificationPolicy.options(
            route: PendingRoute(notification: info), isTest: hermes?["kind"] as? String == "test",
            context: ForegroundNotificationPolicy.context(model))
    }

    // MARK: Taps and buttons

    static func answer(_ response: UNNotificationResponse, center: UNUserNotificationCenter) async {
        let button = response.actionIdentifier
        guard button != UNNotificationDismissActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        let seen = CloudAlertTransport.inspectPayload(info)
        CloudAlertTransport.shared.recordCallback(.opened, result: seen.result)

        if button == ComputerStartedWords.stopAction {
            await stopFromAlert(center: center)
        } else if let eventID = seen.eventID {
            model?.openCloudAlert(eventID: eventID)
        } else {
            let typed = (response as? UNTextInputNotificationResponse)?.userText
            let action = button == UNNotificationDefaultActionIdentifier ? nil : button
            model?.route(from: info, action: action, replyText: typed)
        }
    }

    /// Handles Stop from a "started using your Mac" alert. The system already demanded Face ID or the
    /// passcode, so the stop goes out without launching the app, and the result is posted as a note.
    private static func stopFromAlert(center: UNUserNotificationCenter) async {
        let extraTime = BackgroundTime("nollie.stop.alert")
        defer { extraTime.end() }
        let content = UNMutableNotificationContent()
        content.title = "Nollie"
        content.body = await MacStop.press()
        content.userInfo = ["nollie": "stopResult"]
        let request = UNNotificationRequest(identifier: "nollie.stop." + UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
#endif
