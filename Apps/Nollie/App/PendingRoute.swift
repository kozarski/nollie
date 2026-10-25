import Foundation
import NollieCore

/// Where a notification or link wants to take the person: a stored chat, on a gateway, for a bot,
/// with optional detail about what to do when it opens.
struct PendingRoute: Hashable, Sendable {
    var connectionID: UUID?
    var gateway: String?
    var gatewayFingerprint: String? = nil
    var gatewayIdentity: String? = nil
    var storedSessionID: String
    var profile: String?
    var kind: String?
    var replyText: String?
    /// The question the notification is about. For approvals this is the request id, which every
    /// Companion push carries; otherwise the card id.
    var requestID: String?
    var action: String?
    /// Card behind the local notification this app posted (see `LocalNotifier`).
    var cardID: String?
    /// Tells one request from the next for the same chat, such as the main chat opened twice.
    var token: UUID? = nil
    var messageRowID: Int? = nil
    var messageItemID: String? = nil

    /// The message to scroll to, when the notification pointed at one.
    var messageFocus: NotificationMessageFocus? {
        guard messageRowID != nil || messageItemID != nil else { return nil }
        return NotificationMessageFocus(token: token ?? UUID(), rowID: messageRowID, itemID: messageItemID)
    }

    /// The ids an Approve or Deny may answer (see `ChatSession.approvalToAnswer(named:)`). With
    /// none, only a chat that has exactly one approval can be answered.
    var cardKeys: [String] {
        [cardID, requestID].compactMap { $0 }.filter { $0.isEmpty == false }
    }
}

extension PendingRoute {
    /// Reads a notification's payload. The `hermes` part names the chat, and optionally the card,
    /// gateway and message. Returns nil when it names no valid chat or carries anything malformed.
    init?(notification userInfo: [AnyHashable: Any]) {
        guard let payload = userInfo["hermes"] as? [String: Any],
              let session = payload["session_id"] as? String,
              NotificationNavigation.validIdentifier(session)
        else { return nil }

        var connection: UUID?
        if let raw = payload["connection_id"] {
            guard let text = raw as? String, let parsed = UUID(uuidString: text) else { return nil }
            connection = parsed
        }

        var gatewayText: String?
        if let raw = payload["gateway"] {
            guard let text = raw as? String, (try? GatewayURL.normalize(text)) != nil else { return nil }
            gatewayText = text
        }

        let bot = (payload["profile"] as? String) ?? "default"
        guard NotificationNavigation.validIdentifier(bot), bot.lowercased() != "all" else { return nil }

        self.init(storedSessionID: session)
        connectionID = connection
        gateway = gatewayText
        profile = bot
        kind = payload["kind"] as? String
        requestID = payload["request_id"] as? String
        cardID = payload["card_id"] as? String
        if let row = payload["message_row_id"] as? Int, row > 0 { messageRowID = row }
        if let item = payload["message_item_id"] as? String, !item.isEmpty, item.utf8.count <= 255 {
            messageItemID = item
        }
        token = UUID()
    }
}

/// An extra "are you sure" for approvals made outside the chat, like a notification button.
/// Set in Settings, Security.
struct ApprovalConfirm: Equatable {
    /// Values: "risky" (the default: writes, deletes, spending, or anything the guardian flagged), "all", "off".
    static let modeKey = "approvals.confirmMode"
    /// Earlier plain on/off switch, still honoured where it was set.
    static let key = "approvals.confirmFromOutside"

    static var mode: String {
        let defaults = UserDefaults.standard
        if let chosen = defaults.string(forKey: modeKey) { return chosen }
        if let legacy = defaults.object(forKey: key) as? Bool { return legacy ? "all" : "off" }
        return "risky"
    }

    /// True when an answer given from the Lock Screen or a notification opens the app first, not
    /// applying at once.
    static var isOn: Bool { !(mode == "off") }

    /// Whether this particular approval gets the second question. Asking about everything turns
    /// into a reflexive double tap within a week, so by default it stays rare.
    static func shouldAsk(for approval: ApprovalRequest?) -> Bool {
        let mode = Self.mode
        if mode == "off" { return false }
        if mode == "all" { return true }
        guard let approval else { return true }
        return ApprovalRisk.isRisky(approval)
    }

    var storedID: String
    var cardID: String
    /// "once" or "deny".
    var choice: String
}
