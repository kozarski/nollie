import Foundation

/// What the iPhone and the Watch say to each other over WatchConnectivity. The iPhone holds the
/// link to the Mac, so the Watch only ever asks the phone: for what is waiting and who is working,
/// to answer one approval, or to Stop. Every message is one JSON value under `key`, so either side
/// can tell a message it understands from one it doesn't.
enum WatchWire {
    /// Raised when a message changes shape. A side that gets another version asks for a refresh
    /// and shows nothing it can't read.
    static let version = 1
    /// The dictionary key every message travels under.
    static let key = "nollie.watch"

    // MARK: What the phone sends

    /// Everything the Watch shows, as the phone saw it at `made`.
    struct Snapshot: Codable, Equatable, Sendable {
        var version = WatchWire.version
        var made: Date
        /// Approvals waiting for a yes or no, oldest first.
        var approvals: [Approval]
        /// Helpers working right now, longest-running first.
        var helpers: [Helper]
        /// The phone is linked to a Mac, so Stop has somewhere to go.
        var canStop: Bool
        /// The phone could reach its gateway when it made this.
        var connected: Bool
        /// The newest Night shift card of the last day and a half, worded on the phone. Nil when there is none,
        /// and from a phone that does not send one yet.
        var night: NightNote? = nil

        static func empty(at made: Date = Date(), connected: Bool = false) -> Snapshot {
            Snapshot(made: made, approvals: [], helpers: [], canStop: false, connected: connected)
        }

        /// The same picture, ignoring when it was taken: the phone only sends one that changed.
        func sameAs(_ other: Snapshot?) -> Bool {
            guard var other else { return false }
            other.made = made
            return other == self
        }
    }

    /// One approval card, worded on the phone exactly as its card in the chat words it.
    struct Approval: Codable, Equatable, Identifiable, Sendable {
        /// The card's id, which the answer names.
        var id: String
        var requestID: String
        /// The chat it waits in, the bot that asks and the gateway it came from.
        var chatID: String
        var profile: String
        var connectionID: String
        var botName: String
        /// The character still (`character-<look>-avatar`).
        var avatar: String
        var symbol: String
        var title: String
        var body: String
        /// Ask first's "You're about to press …" line, when there is one.
        var check: String?
        var command: String?
        /// Whether Allow once may be given from the wrist, or only Deny.
        var answers: Answers
        /// A risky one asks "Allow once?" again before the yes goes.
        var asksAgain: Bool
        /// The safety check flagged it.
        var flagged: Bool
    }

    /// What the crew did overnight, as the Night shift card in Settings says it, in a few lines for the wrist.
    struct NightNote: Codable, Equatable, Sendable {
        /// When the card's window ended.
        var at: Date
        /// "Since 7:02 yesterday".
        var since: String?
        /// "2 runs · 5 actions · 1 held", or the quiet night's line.
        var counts: String
        /// The first few runs: the schedule or task, and "Scout · Done · 3:10".
        var runs: [Line]
        /// Runs past the ones listed.
        var more: Int
        /// Something was held or stopped, so the page wears the warning tint.
        var needsLook: Bool

        struct Line: Codable, Equatable, Sendable {
            var title: String
            var detail: String
        }
    }

    enum Answers: String, Codable, Equatable, Sendable {
        /// Allow once and Deny.
        case allowOrDeny
        /// Only Deny here: the yes needs the iPhone (Face ID, a saved sign-in, using the Mac).
        case denyOnly
    }

    /// One helper at work.
    struct Helper: Codable, Equatable, Identifiable, Sendable {
        var id: String { profile }
        var profile: String
        var name: String
        var avatar: String
        /// Where it is using a computer, or nil when it is only working in a chat.
        var place: HelperWorkPlace?
        var since: Date
    }

    // MARK: What the Watch asks

    enum Choice: String, Codable, Equatable, Sendable {
        case once, deny
    }

    /// An answer to one card, naming it exactly. The phone never answers a different card.
    struct Answer: Codable, Equatable, Sendable {
        var cardID: String
        var requestID: String
        var chatID: String
        var profile: String
        var connectionID: String
        var choice: Choice
    }

    enum Request: Codable, Equatable, Sendable {
        /// Send the newest snapshot.
        case refresh
        case answer(Answer)
        /// Deny pressed on a notification shown on the Watch: its `hermes` details, which the phone
        /// carries out exactly as Deny on the same notification on the phone.
        case notificationDeny([String: String])
        /// The same Stop the Lock Screen offers.
        case stop
    }

    /// The text details of a notification's `hermes` payload, all a Deny needs to find its card.
    static func notificationDetails(_ userInfo: [AnyHashable: Any]) -> [String: String]? {
        guard let hermes = userInfo["hermes"] as? [String: Any], hermes["session_id"] is String else { return nil }
        return hermes.compactMapValues { $0 as? String }
    }

    /// The phone's reply to a request: how it went in a few words, and the picture afterwards.
    struct Reply: Codable, Equatable, Sendable {
        var version = WatchWire.version
        var done: Bool
        var line: String?
        var snapshot: Snapshot?
    }

    /// A request with the version that sent it.
    private struct Envelope<Body: Codable>: Codable {
        var version: Int
        var body: Body
    }

    // MARK: Encoding

    enum Problem: Error, Equatable {
        case missing, otherVersion(Int), unreadable
    }

    private static let encoder: JSONEncoder = {
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .secondsSince1970
        return coder
    }()

    private static let decoder: JSONDecoder = {
        let coder = JSONDecoder()
        coder.dateDecodingStrategy = .secondsSince1970
        return coder
    }()

    static func message(_ request: Request) -> [String: Any] {
        [key: (try? encoder.encode(Envelope(version: version, body: request))) ?? Data()]
    }

    static func message(_ reply: Reply) -> [String: Any] {
        [key: (try? encoder.encode(reply)) ?? Data()]
    }

    static func message(_ snapshot: Snapshot) -> [String: Any] {
        [key: (try? encoder.encode(snapshot)) ?? Data()]
    }

    static func request(from message: [String: Any]) throws(Problem) -> Request {
        let envelope = try read(Envelope<Request>.self, from: message)
        guard envelope.version == version else { throw .otherVersion(envelope.version) }
        return envelope.body
    }

    static func reply(from message: [String: Any]) throws(Problem) -> Reply {
        let reply = try read(Reply.self, from: message)
        guard reply.version == version else { throw .otherVersion(reply.version) }
        return reply
    }

    static func snapshot(from message: [String: Any]) throws(Problem) -> Snapshot {
        let snapshot = try read(Snapshot.self, from: message)
        guard snapshot.version == version else { throw .otherVersion(snapshot.version) }
        return snapshot
    }

    static func encode(_ snapshot: Snapshot) -> Data? { try? encoder.encode(snapshot) }

    static func decodeSnapshot(_ data: Data) -> Snapshot? {
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data), snapshot.version == version else { return nil }
        return snapshot
    }

    private static func read<T: Decodable>(_ type: T.Type, from message: [String: Any]) throws(Problem) -> T {
        guard let data = message[key] as? Data else { throw .missing }
        do { return try decoder.decode(type, from: data) } catch { throw .unreadable }
    }
}

/// Names shared with the iPhone's notifications, so a banner mirrored to the Watch keeps its
/// buttons. Tests hold them equal to the iPhone's own.
enum WatchNotificationNames {
    static let approvalCategory = "HERMES_APPROVAL"
    static let approveOnceAction = "HERMES_APPROVE_ONCE"
    static let denyAction = "HERMES_DENY"
    static let computerCategory = "NOLLIE_COMPUTER"
    static let stopAction = "NOLLIE_STOP_MAC"
}

/// The words the Watch shows. Few, short and shared, so the tests can hold them to the copy rules.
enum WatchWords {
    static let allowOnce = "Allow once"
    static let deny = "Deny"
    static let allowAgain = "Allow once?"
    static let approveOnPhone = "Approve on your iPhone"
    static let stop = "Stop"
    static let working = "Working"
    static let allQuiet = "All quiet"
    static let nobodyWorking = "No helpers working"
    static let openPhone = "Open Nollie on your iPhone"
    static let phoneAway = "Can't reach your iPhone"
    static let allowed = "Allowed"
    static let denied = "Denied"
    static let gone = "Already answered"
    static let flagged = "The safety check flagged this one."
    static let lastSeen = "Last seen"
    static let nightShift = "Night shift"

    /// "2 more", under the runs a busy night's note leaves out.
    static func more(_ n: Int) -> String { "\(n) more" }

    /// "2 helpers working", "1 helper working".
    static func count(_ n: Int) -> String {
        n == 0 ? nobodyWorking : "\(n) \(n == 1 ? "helper" : "helpers") working"
    }

    /// What a helper is doing, under its name.
    static func doing(_ place: HelperWorkPlace?) -> String {
        switch place {
        case .mac: "Using your Mac"
        case .ownComputer: "Using its computer"
        case nil: working
        }
    }
}
