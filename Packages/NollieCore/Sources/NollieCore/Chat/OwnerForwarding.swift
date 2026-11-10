import Foundation

/// Hermes 0.23: when the gateway itself is running a turn in a chat (a schedule, a message from another app), a
/// prompt sent from here is handed to that turn's owner and queued behind it. `prompt.submit` then answers
/// `{status: "queued", admission_id, forwarded: true}`, and only `message.start` and `message.complete` come back
/// for it (no words or steps as they happen), so the stored history is read again at the end. Or the owner can't
/// take it, and the answer is error 4090 with one of these reasons.
public enum OwnerRefusal: String, Sendable, Equatable {
    /// Nothing was sent; it can go again once the other turn ends.
    case busy = "SESSION_OWNER_BUSY"
    /// The owner did not confirm in time. It may still run, so it is never sent again by itself.
    case unconfirmed = "SESSION_OWNER_UNCONFIRMED"
    /// Work in the gateway's queue that only the gateway can settle.
    case notOwned = "SESSION_NOT_OWNED"

    public static let code = 4090

    /// The refusal a `prompt.submit` error stands for, if it is one of these.
    public init?(code: Int, reason: String?) {
        guard code == Self.code, let reason, let known = OwnerRefusal(rawValue: reason) else { return nil }
        self = known
    }

    public init?(code: Int, data: JSONValue?) { self.init(code: code, reason: data?["reason"]?.stringValue) }

    public init?(_ error: Error) {
        if let rpc = error as? RPCError {
            self.init(code: rpc.code, data: rpc.data)
        } else {
            return nil
        }
    }

    /// Whether to offer Try again.
    public var offersRetry: Bool { self == .busy }

    /// What the chat says, in a few plain words.
    public var words: String {
        switch self {
        case .busy:
            String(localized: "The other chat is still busy, so nothing was sent.", table: "Core")
        case .unconfirmed:
            String(localized: "The other chat did not confirm this message. It may still arrive, so check before sending it again.", table: "Core")
        case .notOwned:
            String(localized: "Hermes is still finishing work in this chat elsewhere, so nothing was sent.", table: "Core")
        }
    }

    /// Whether a `prompt.submit` answer says the prompt went to the chat's owner.
    public static func isForwarded(_ answer: JSONValue) -> Bool {
        answer["forwarded"]?.boolValue == true && answer["status"]?.stringValue == "queued"
    }
}
