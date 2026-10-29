import Foundation

// What travels inside a sealed away record. Read strictly: a kind not listed here, a missing or
// extra field, or a value of the wrong shape is no note at all. See Docs/specs/away-icloud.md.

/// An approval card as the phone shows it: the words Hermes gave and the two choices allowed away.
public struct AwayApproval: Equatable, Sendable {
    public var command: String?
    public var description: String?
    public var toolName: String?
    public var patternKey: String?
    /// Always a subset of `once` and `deny`.
    public var choices: [String]

    public init(command: String? = nil, description: String? = nil, toolName: String? = nil,
                patternKey: String? = nil, choices: [String]) {
        self.command = command
        self.description = description
        self.toolName = toolName
        self.patternKey = patternKey
        self.choices = choices
    }
}

/// Why a card closed.
public enum AwayCardOutcome: String, Sendable, CaseIterable {
    /// The phone's answer was given to Hermes.
    case answered
    /// Someone answered it on the Mac first.
    case answeredOnMac
    /// Hermes took the question back.
    case withdrawn
    /// Its ten minutes ran out: answer on the Mac.
    case expired
}

/// Why the Mac said no. Fixed codes: the phone words them.
public enum AwayRefusal: String, Error, Sendable, CaseIterable {
    case notAllowed, slashCommand, tooLong, empty, privateBot, unknownBot, unknownChat, expired, unknownCard, busy, notReady
}

/// A helper as the status note gives it.
public struct AwayHelper: Equatable, Sendable {
    public var bot: String
    public var name: String
    public var working: Bool
    /// Cards waiting on the person for this helper, on the Mac.
    public var waiting: Int

    public init(bot: String, name: String, working: Bool, waiting: Int) {
        self.bot = bot
        self.name = name
        self.working = working
        self.waiting = waiting
    }
}

public enum AwayNote: Equatable, Sendable {
    // Phone to Mac: the allowlist. Nothing else can be asked for.
    case send(bot: String, chat: String?, text: String)
    case answer(card: String, choice: String)
    case stop
    case status

    // Mac to phone.
    case received(request: String, chat: String?)
    case reply(request: String, bot: String, chat: String, text: String)
    case card(card: String, request: String, bot: String, chat: String, approval: AwayApproval, expiresAt: Date)
    case closed(card: String, outcome: AwayCardOutcome)
    case stopped(request: String, paused: Int)
    case helpers(request: String?, helpers: [AwayHelper])
    case refused(request: String, reason: AwayRefusal)

    public var kind: String {
        switch self {
        case .send: "send"
        case .answer: "answer"
        case .stop: "stop"
        case .status: "status"
        case .received: "received"
        case .reply: "reply"
        case .card: "card"
        case .closed: "closed"
        case .stopped: "stopped"
        case .helpers: "helpers"
        case .refused: "refused"
        }
    }

    /// Who may send this kind. A Mac never takes a Mac's kind and a phone never takes a phone's.
    public var sentBy: AwaySide {
        switch self {
        case .send, .answer, .stop, .status: .phone
        default: .mac
        }
    }
}

/// A note with its id and when it was written, as sealed.
public struct AwayLetter: Equatable, Sendable {
    public var id: String
    public var at: Date
    public var note: AwayNote

    public init(id: String, at: Date, note: AwayNote) {
        self.id = id
        self.at = at
        self.note = note
    }

    /// The largest note, before sealing.
    public static let maximumSize = 64 * 1024

    public func encoded() throws -> Data {
        var object: [String: Any] = ["v": 1, "id": id, "at": Int64(at.timeIntervalSince1970.rounded(.down)), "kind": note.kind]
        switch note {
        case .send(let bot, let chat, let text):
            object["bot"] = bot; object["text"] = text
            if let chat { object["chat"] = chat }
        case .answer(let card, let choice):
            object["card"] = card; object["choice"] = choice
        case .stop, .status:
            break
        case .received(let request, let chat):
            object["request"] = request
            if let chat { object["chat"] = chat }
        case .reply(let request, let bot, let chat, let text):
            object["request"] = request; object["bot"] = bot; object["chat"] = chat; object["text"] = text
        case .card(let card, let request, let bot, let chat, let approval, let expiresAt):
            object["card"] = card; object["request"] = request; object["bot"] = bot; object["chat"] = chat
            object["until"] = Int64(expiresAt.timeIntervalSince1970.rounded(.down))
            var shown: [String: Any] = ["choices": approval.choices]
            if let value = approval.command { shown["command"] = value }
            if let value = approval.description { shown["description"] = value }
            if let value = approval.toolName { shown["tool"] = value }
            if let value = approval.patternKey { shown["pattern"] = value }
            object["approval"] = shown
        case .closed(let card, let outcome):
            object["card"] = card; object["outcome"] = outcome.rawValue
        case .stopped(let request, let paused):
            object["request"] = request; object["paused"] = paused
        case .helpers(let request, let helpers):
            if let request { object["request"] = request }
            object["helpers"] = helpers.map { ["bot": $0.bot, "name": $0.name, "working": $0.working, "waiting": $0.waiting] as [String: Any] }
        case .refused(let request, let reason):
            object["request"] = request; object["reason"] = reason.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= Self.maximumSize else { throw AwayChannel.Failure.tooBig }
        return data
    }

    /// A strict read. Nil for anything that is not exactly one of the notes above.
    public static func decode(_ data: Data) -> AwayLetter? {
        guard data.count <= maximumSize, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              int(object["v"]) == 1, let id = object["id"] as? String, AwayHeader.isValidID(id),
              let seconds = int(object["at"]), seconds > 0, let kind = object["kind"] as? String else { return nil }
        let at = Date(timeIntervalSince1970: TimeInterval(seconds))
        let base: Set<String> = ["v", "id", "at", "kind"]
        func keys(_ required: Set<String>, optional: Set<String> = []) -> Bool {
            let present = Set(object.keys).subtracting(base)
            return required.isSubset(of: present) && present.isSubset(of: required.union(optional))
        }
        func text(_ key: String) -> String? { object[key] as? String }
        let note: AwayNote
        switch kind {
        case "send":
            guard keys(["bot", "text"], optional: ["chat"]), let bot = text("bot"), let body = text("text") else { return nil }
            if object["chat"] != nil, text("chat") == nil { return nil }
            note = .send(bot: bot, chat: text("chat"), text: body)
        case "answer":
            guard keys(["card", "choice"]), let card = text("card"), let choice = text("choice") else { return nil }
            note = .answer(card: card, choice: choice)
        case "stop":
            guard keys([]) else { return nil }
            note = .stop
        case "status":
            guard keys([]) else { return nil }
            note = .status
        case "received":
            guard keys(["request"], optional: ["chat"]), let request = text("request") else { return nil }
            if object["chat"] != nil, text("chat") == nil { return nil }
            note = .received(request: request, chat: text("chat"))
        case "reply":
            guard keys(["request", "bot", "chat", "text"]), let request = text("request"), let bot = text("bot"),
                  let chat = text("chat"), let body = text("text") else { return nil }
            note = .reply(request: request, bot: bot, chat: chat, text: body)
        case "card":
            guard keys(["card", "request", "bot", "chat", "until", "approval"]), let card = text("card"),
                  let request = text("request"), let bot = text("bot"), let chat = text("chat"),
                  let until = int(object["until"]), let shown = object["approval"] as? [String: Any],
                  Set(shown.keys).isSubset(of: ["choices", "command", "description", "tool", "pattern"]),
                  let choices = shown["choices"] as? [String] else { return nil }
            for key in ["command", "description", "tool", "pattern"] where shown[key] != nil && !(shown[key] is String) { return nil }
            let approval = AwayApproval(command: shown["command"] as? String, description: shown["description"] as? String,
                                        toolName: shown["tool"] as? String, patternKey: shown["pattern"] as? String, choices: choices)
            note = .card(card: card, request: request, bot: bot, chat: chat, approval: approval,
                         expiresAt: Date(timeIntervalSince1970: TimeInterval(until)))
        case "closed":
            guard keys(["card", "outcome"]), let card = text("card"),
                  let outcome = text("outcome").flatMap(AwayCardOutcome.init(rawValue:)) else { return nil }
            note = .closed(card: card, outcome: outcome)
        case "stopped":
            guard keys(["request", "paused"]), let request = text("request"), let paused = int(object["paused"]), paused >= 0 else { return nil }
            note = .stopped(request: request, paused: Int(paused))
        case "helpers":
            guard keys(["helpers"], optional: ["request"]), let list = object["helpers"] as? [[String: Any]], list.count <= 64 else { return nil }
            if object["request"] != nil, text("request") == nil { return nil }
            var helpers: [AwayHelper] = []
            for entry in list {
                guard Set(entry.keys) == ["bot", "name", "working", "waiting"], let bot = entry["bot"] as? String,
                      let name = entry["name"] as? String, let working = boolean(entry["working"]),
                      let waiting = int(entry["waiting"]), waiting >= 0 else { return nil }
                helpers.append(AwayHelper(bot: bot, name: name, working: working, waiting: Int(waiting)))
            }
            note = .helpers(request: text("request"), helpers: helpers)
        case "refused":
            guard keys(["request", "reason"]), let request = text("request"),
                  let reason = text("reason").flatMap(AwayRefusal.init(rawValue:)) else { return nil }
            note = .refused(request: request, reason: reason)
        default:
            return nil
        }
        return AwayLetter(id: id, at: at, note: note)
    }

    /// Whole numbers only: JSON `true` is not 1 here, and 1.5 is not a number of anything.
    private static func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 1e15 else { return nil }
        return number.int64Value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
