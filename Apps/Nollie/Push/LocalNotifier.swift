import Foundation
import UserNotifications
import NollieCore
#if canImport(UIKit)
import UIKit
#endif

/// Gives the core a way to post local notifications without depending on UserNotifications.
@MainActor
final class LocalCardNotifier: CardNotifying {
    func cardArrived(_ card: PendingCard, chat: ChatSession) {
        LocalNotifier.announce(.card(card), in: chat)
    }

    func turnFinished(chat: ChatSession, error: String?) {
        LocalNotifier.announce(.finished(error: error), in: chat)
    }

    func cardSettled(_ card: PendingCard, chat: ChatSession) {
        LocalNotifier.takeDown(card)
    }
}

/// Banners the app raises on its own for cards and finished turns, only while it is off screen.
enum LocalNotifier {
    /// Category and action names, shared with the companion's pushes and the notification extensions.
    private enum Name {
        static let prefix = "HERMES_"
    }

    static let approvalCategory = Name.prefix + "APPROVAL"
    static let clarifyCategory = Name.prefix + "CLARIFY"
    static let turnCategory = Name.prefix + "TURN"
    static let errorCategory = Name.prefix + "ERROR"
    static let approveOnceAction = Name.prefix + "APPROVE_ONCE"
    static let denyAction = Name.prefix + "DENY"
    static let replyAction = Name.prefix + "REPLY"

    @MainActor static var isForeground = true

    /// True once the companion is known to push to this device. A device registered with a gateway
    /// lacking the companion would wait for pushes that never arrive and show nothing on its own.
    @MainActor static var companionDelivers: Bool {
        let model = AppModel.shared
        return PushRelay.isConfigured && model.push.registeredAt != nil && model.companionInstalledVersion != nil
    }

    /// A reply from a notification speaks as the person, so a locked phone asks for Face ID first.
    static let replyOptions: UNNotificationActionOptions = [.authenticationRequired]

    // MARK: Categories

    static func registerCategories() {
        // Under Settings, Security, "Confirm approvals" decides what the buttons do. On: they launch the
        // app and the card checks once more. Off: the answer goes straight from the notification.
        let opensApp: UNNotificationActionOptions = ApprovalConfirm.isOn ? [.foreground] : []
        let approve = UNNotificationAction(identifier: approveOnceAction, title: "Allow once",
                                           options: approveOptions(confirm: ApprovalConfirm.isOn, ownerCheck: ApprovalOwnerCheck.isOn()))
        // Saying no is always safe, so Deny never asks to unlock, here or mirrored on the Watch.
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: opensApp.union(.destructive))
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: replyOptions,
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let layout: [(String, [UNNotificationAction])] = [
            (approvalCategory, [approve, deny]), (clarifyCategory, []), (turnCategory, [reply]),
            (errorCategory, []), ("HERMES_ENC", []), ("HERMES_TEST", []),
        ]
        var categories = layout.map { UNNotificationCategory(identifier: $0.0, actions: $0.1, intentIdentifiers: [], options: []) }
        #if os(iOS)
        // "Scout started using your Mac" offers Stop, behind Face ID on a locked phone.
        let stop = UNNotificationAction(identifier: ComputerStartedWords.stopAction, title: ComputerStartedWords.stop,
                                        options: [.authenticationRequired, .destructive])
        categories.append(UNNotificationCategory(identifier: ComputerStartedWords.category, actions: [stop], intentIdentifiers: [], options: []))
        #endif
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    /// Approve always needs the phone unlocked. It opens the app when approvals are confirmed there,
    /// and while Face ID for buying and sending is on, since a push doesn't say which kind of approval
    /// it carries and Face ID can only be asked in the app. Deny never asks to unlock.
    static func approveOptions(confirm: Bool, ownerCheck: Bool) -> UNNotificationActionOptions {
        (confirm || ownerCheck) ? [.foreground, .authenticationRequired] : [.authenticationRequired]
    }

    // MARK: Taking notifications down

    private static func removeDelivered(matching test: @escaping @Sendable (UNNotification) -> Bool) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { all in
            let ids = all.filter(test).map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Removes the delivered notifications of one chat: its thread, or any push whose payload names
    /// the session. Given a connection, the push must also come from that gateway and profile.
    static func clearDelivered(for storedID: String, connection: GatewayConnection? = nil, profile: String? = nil) {
        guard !storedID.isEmpty else { return }
        removeDelivered { note in
            let payload = note.request.content.userInfo["hermes"] as? [String: Any]
            if let connection {
                let fromThisGateway = (payload?["connection_id"] as? String) == connection.id.uuidString
                    || (payload?["gateway"] as? String).flatMap({ try? GatewayURL.normalize($0) }) == connection.gateway
                guard fromThisGateway, (payload?["profile"] as? String ?? "default") == (profile ?? "default") else { return false }
            }
            return note.request.content.threadIdentifier == storedID || (payload?["session_id"] as? String) == storedID
        }
    }

    /// Clears the banner for a card that was answered on another device. It may have come from
    /// this app ("card-<id>") or from the companion, whose payload names the request.
    static func takeDown(_ card: PendingCard) {
        let localID = "card-\(card.id)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [localID])
        var names: Set<String> = [card.id]
        if let request = card.approval?.requestId { names.formUnion([request, "queue-" + request]) }
        let wanted = names
        removeDelivered { note in
            if note.request.identifier == localID || wanted.contains(note.request.identifier) { return true }
            let payload = note.request.content.userInfo["hermes"] as? [String: Any]
            return wanted.contains(payload?["request_id"] as? String ?? "")
        }
    }

    // MARK: Posting

    /// Something worth a banner.
    enum Event {
        case card(PendingCard)
        case finished(error: String?)
    }

    /// The words of one notification, before it is given its thread and details.
    private struct Banner {
        let title: String
        let body: String
        let category: String

        @MainActor
        init(_ event: Event, bot: String, chat: ChatSession) {
            switch event {
            case .card(let card) where card.approval != nil:
                let approval = card.approval!
                let described = approval.description ?? ""
                self.init(title: bot + " · approval needed",
                          body: described.isEmpty ? (approval.command ?? "A command needs your okay") : described,
                          category: LocalNotifier.approvalCategory)
            case .card(let card) where card.clarify != nil:
                let ask = card.clarify!
                self.init(title: bot + " · question",
                          body: ask.question ?? ask.questions?.first?.question ?? "Hermes needs an answer",
                          category: LocalNotifier.clarifyCategory)
            case .card(let card):
                self.init(title: bot + " · input needed",
                          body: card.valuePrompt?.prompt ?? "Hermes is asking for a value",
                          category: LocalNotifier.clarifyCategory)
            case .finished(let error?) where !error.isEmpty:
                self.init(title: bot + " · turn failed", body: error, category: LocalNotifier.errorCategory)
            case .finished:
                let lastReply = chat.items.last { item in
                    if case .assistant = item.kind { return true }
                    return false
                }
                var text = "Turn finished"
                if case .assistant(let said, _, _)? = lastReply?.kind { text = String(said.prefix(180)) }
                self.init(title: bot, body: text, category: LocalNotifier.turnCategory)
            }
        }

        private init(title: String, body: String, category: String) {
            (self.title, self.body, self.category) = (title, body, category)
        }
    }

    /// Posts a banner for the event, unless the app is in front or the companion already delivers.
    @MainActor
    fileprivate static func announce(_ event: Event, in chat: ChatSession) {
        #if os(iOS)
        // With the app in front the card is already on screen: a buzz is enough.
        if isForeground, case .card = event { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        #endif
        if isForeground || companionDelivers { return }
        // A helper muted from the weekly note: no banner for its replies. Its questions still come through.
        if case .finished = event, HelperMute.isMuted(chat.profileName, connection: chat.runtime.connection.id) { return }
        let bot = chat.runtime.profiles.first(where: { $0.name == chat.profileName })?.label ?? chat.profileName
        let banner = Banner(event, bot: bot, chat: chat)
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        content.categoryIdentifier = banner.category
        content.subtitle = chat.title // the bot is the sender; the title acts as a thread name
        content.threadIdentifier = chat.storedID
        content.sound = .default
        switch event {
        case .card(let card):
            content.userInfo = userInfo(chat: chat, kind: card.method, card: card)
            content.interruptionLevel = .timeSensitive
            post(content, id: "card-" + card.id)
        case .finished:
            content.userInfo = userInfo(chat: chat, kind: "turn", card: nil)
            post(content, id: "turn-\(chat.storedID)-\(Int(Date().timeIntervalSince1970))")
        }
    }

    /// Payload returned on a tap or button (see `PendingRoute`): identifies the chat and, when it
    /// is a card, the card and its request too, so Approve answers exactly that one.
    @MainActor
    static func userInfo(chat: ChatSession, kind: String, card: PendingCard? = nil) -> [String: Any] {
        let connection = chat.runtime.connection
        var details: [String: Any] = [
            "kind": kind,
            "session_id": chat.storedID,
            "profile": chat.profileName,
            "connection_id": connection.id.uuidString,
            "gateway": connection.gateway.description,
        ]
        if kind == "turn", let newest = chat.items.last(where: { $0.isAssistantOrError }) {
            if let row = newest.rowID, row > 0 { details["message_row_id"] = row }
            details["message_item_id"] = newest.id
        }
        if let card {
            details.merge(["card_id": card.id, "request_id": card.approval?.requestId ?? card.id]) { $1 }
        }
        return ["hermes": details]
    }

    /// Whether text may appear on the lock screen: the preview policy must allow it, and the bot must
    /// be named and not private.
    static func showsPreview(policy: NotificationPreviewPolicy?, profile: String?, connection: UUID? = nil) -> Bool {
        let name = profile?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return policy?.allowsPreview == true && !name.isEmpty && !PrivateBots.isPrivate(name, connection: connection, fresh: true)
    }

    // MARK: Helpers

    private static func post(_ content: UNMutableNotificationContent, id: String) {
        let hermes = content.userInfo["hermes"] as? [String: Any]
        let profile = hermes?["profile"] as? String
        let connection = (hermes?["connection_id"] as? String).flatMap { UUID(uuidString: $0) }
        if !showsPreview(policy: NotificationPreviewPolicy.load(), profile: profile, connection: connection) {
            content.title = "Nollie"
            content.subtitle = ""
            content.body = "There’s an update waiting for you in Nollie."
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

private extension TranscriptItem {
    /// The kinds of row a finished turn can end on.
    var isAssistantOrError: Bool {
        switch kind {
        case .assistant, .error: true
        default: false
        }
    }
}
