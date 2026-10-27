import AppKit
import NollieCore
import UserNotifications

/// What the Mac does with a notification once the delegate has handed it over: how it shows while
/// Nollie is in front, and where a tap goes. Everything is recorded with the cloud alert transport
/// so the Companion's delivery checks can see what arrived.
@MainActor
enum MacNotificationDesk {
    private static var transport: CloudAlertTransport { .shared }

    /// A remote push that arrived while the app runs: noted, and its receipt sent.
    static func noteRemote(_ userInfo: [String: Any]) {
        let payload = CloudAlertTransport.inspectPayload(userInfo)
        transport.recordCallback(.remote, result: payload.result)
        guard let eventID = payload.eventID else { return }
        Task { await transport.recordReceipt(eventID: eventID, opened: false) }
    }

    /// How a notification that comes in while Nollie is in front should look, if at all.
    static func presentation(for notification: UNNotification) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let payload = CloudAlertTransport.inspectPayload(userInfo)
        transport.recordCallback(.foreground, result: payload.result)
        let context = ForegroundNotificationPolicy.context(MacAppDelegate.model)

        if WeeklyNoteReminder.isWeekly(userInfo) { return [.banner, .list] }
        guard let eventID = payload.eventID else {
            let kind = (userInfo["hermes"] as? [String: Any])?["kind"] as? String
            return ForegroundNotificationPolicy.options(route: PendingRoute(notification: userInfo),
                                                        isTest: kind == "test", context: context)
        }
        Task { await transport.recordReceipt(eventID: eventID, opened: false) }
        let event = await ForegroundNotificationLookup.resolve {
            await transport.foregroundEvent(eventID: eventID)
        }
        return ForegroundNotificationPolicy.options(event: event, context: context)
    }

    /// A tap on a notification or one of its buttons. A cloud alert opens its page; anything else is
    /// routed from its payload, with the button chosen and any text typed into the reply box.
    static func open(_ response: UNNotificationResponse) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        let payload = CloudAlertTransport.inspectPayload(userInfo)
        transport.recordCallback(.opened, result: payload.result)

        if let eventID = payload.eventID {
            MacAppDelegate.model?.openCloudAlert(eventID: eventID)
            return
        }
        if WeeklyNoteReminder.isWeekly(userInfo) {
            MacWindow.openMain?()
            MacAppDelegate.model?.weeklyRequest = UUID()
            return
        }
        let button = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        MacAppDelegate.model?.route(from: userInfo, action: button, replyText: typed)
    }
}
