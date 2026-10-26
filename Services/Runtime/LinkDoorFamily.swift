#if os(macOS)
import Foundation

/// Sharing a helper with someone at home (Docs/specs/family-sharing.md): what a member's phone may
/// reach through the door, and the owner's routes for sharing. All of it is decided here, on the Mac;
/// the member's screens only follow.
enum LinkDoorFamily {
    // MARK: Private helpers

    /// Always private, saved list or not, and never shareable.
    static let alwaysPrivate: Set<String> = ["private", "moss"]

    /// Hermes's own profile id grammar: `[a-z0-9][a-z0-9_-]{0,63}`.
    static func validProfile(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= 64, isLowerAlnum(first) else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == 45 || $0 == 95 }
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...122).contains(byte) }

    /// True when a name is a private helper's, as the add-on decides it: the whole name or any word in it.
    static func isPrivate(_ name: String, list: Set<String>) -> Bool {
        let all = list.union(alwaysPrivate)
        let text = name.lowercased()
        let words = Set([text] + text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }).map(String.init)
                        + text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        return !words.isDisjoint(with: all)
    }

    // MARK: Small yeses

    /// The kinds of ask a member may allow themselves when the owner turned on Small yeses: none yet.
    /// Every approval Hermes and Nollie raise today sends, buys, posts, deletes, uses a computer or runs
    /// code, so they all go to the owner. Ask first's kinds can never be added here.
    static let smallKinds: Set<String> = []

    /// Whether an approval Hermes sent is of a small kind. An ask with no rule key, or with any key from
    /// Ask first, a saved sign-in or a computer, is not.
    static func isSmall(_ request: [String: Any], kinds: Set<String> = smallKinds) -> Bool {
        var raw: [Any] = (request["pattern_keys"] as? [Any]) ?? []
        if let key = request["pattern_key"] { raw.insert(key, at: 0) }
        let keys = raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return false }
        for key in keys {
            if key.contains("nollie-ask-first:") || key.contains("nollie-sign-in:") || key.hasPrefix("cua:") { return false }
            if !kinds.contains(key) { return false }
        }
        return true
    }

    // MARK: Routes

    /// The door's own routes for sharing, under `/nollie/family`.
    enum Route: Equatable, Sendable {
        /// Who this device is: owner or member, and what a member was given.
        case me
        /// Owners: the members and their open asks.
        case overview
        /// Owners: a code for someone at home.
        case invite
        case update(UUID)
        case remove(UUID)
        /// Owners: Allow once or Deny to a member's ask.
        case answer(String)
        case refused
    }

    static let prefix = "/nollie/family"
    /// What a member hears when they try something only the owner may do.
    static let ownerOnly = "Ask the person who shared this."

    static func isFamilyPath(_ path: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }

    static func route(method: String, path: String, websocket: Bool) -> Route {
        guard !websocket else { return .refused }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard parts.count >= 2, parts[0] == "nollie", parts[1] == "family", !parts.contains(where: \.isEmpty) else { return .refused }
        let rest = Array(parts.dropFirst(2))
        switch (method, rest.count) {
        case ("GET", 0): return .overview
        case ("GET", 1) where rest[0] == "me": return .me
        case ("POST", 1) where rest[0] == "invite": return .invite
        case ("PUT", 2) where rest[0] == "members": return UUID(uuidString: rest[1]).map { .update($0) } ?? .refused
        case ("DELETE", 2) where rest[0] == "members": return UUID(uuidString: rest[1]).map { .remove($0) } ?? .refused
        case ("POST", 2) where rest[0] == "asks": return validAskID(rest[1]) ? .answer(rest[1]) : .refused
        default: return .refused
        }
    }

    static func validAskID(_ id: String) -> Bool {
        (1...80).contains(id.utf8.count) && id.utf8.allSatisfy { isLowerAlnum($0) || (65...90).contains($0) || $0 == 45 || $0 == 95 }
    }

    /// What a member's plain request may do. Only routes the owner's allowlist already lets through
    /// are ever asked about here.
    enum MemberRoute: Equatable, Sendable {
        /// Passed to Hermes unchanged: status and health.
        case pass
        /// Answered by the door: the shared helpers only.
        case profiles
        /// Answered by the door: this member's chats with one helper.
        case chats(profile: String)
        /// Passed to Hermes when this chat is theirs, with a helper still shared.
        case chat(LinkDoorDevices.Chat)
        /// The member's chat socket, under the member's own rules.
        case socket
        case refused
    }

    static func memberRoute(method: String, path: String, query: String?, websocket: Bool) -> MemberRoute {
        if websocket { return path == "/api/ws" ? .socket : .refused }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard parts.first == "api", parts.count >= 2 else { return .refused }
        switch (method, Array(parts.dropFirst())) {
        case ("GET", ["status"]), ("GET", ["health"]):
            return .pass
        case ("GET", ["profiles"]):
            return query.map(\.isEmpty) ?? true ? .profiles : .refused
        case ("GET", ["sessions"]):
            return onlyProfile(query, others: listQueryNames).map { .chats(profile: $0) } ?? .refused
        case (_, let rest) where rest.count == 2 && rest[0] == "sessions" && ["GET", "PATCH", "DELETE"].contains(method):
            guard validChatID(rest[1]), let profile = onlyProfile(query, others: []) else { return .refused }
            return .chat(.init(id: rest[1], profile: profile))
        case ("GET", let rest) where rest.count == 3 && rest[0] == "sessions" && rest[2] == "messages":
            guard validChatID(rest[1]), let profile = onlyProfile(query, others: messageQueryNames) else { return .refused }
            return .chat(.init(id: rest[1], profile: profile))
        default:
            return .refused
        }
    }

    /// Query names the session list may carry besides `profile`; the door answers it, so they are only read.
    static let listQueryNames: Set<String> = ["limit", "offset", "archived", "order", "min_messages"]
    /// Paging a chat's messages.
    static let messageQueryNames: Set<String> = ["limit", "before", "after", "offset", "inline_images", "order"]

    /// The one `profile` in a query, when every other name is one of `others` and none repeats.
    static func onlyProfile(_ query: String?, others: Set<String>) -> String? {
        guard let query, !query.isEmpty else { return nil }
        var profile: String?
        var seen = Set<String>()
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let name = parts[0].removingPercentEncoding, let value = parts[1].removingPercentEncoding,
                  seen.insert(name).inserted else { return nil }
            if name == "profile" {
                guard validProfile(value) else { return nil }
                profile = value
            } else if !others.contains(name) || value.utf8.count > 64 {
                return nil
            }
        }
        return profile
    }

    /// A stored session id as Hermes makes them (`20261020_093000_ab12cd`), never a path or a title.
    static func validChatID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { isLowerAlnum($0) || (65...90).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
            && id != "." && id != ".."
    }

    // MARK: Answers the door gives a member

    /// `/api/profiles` with only the helpers this member may reach, and only the fields a chat needs.
    static func filterProfiles(_ body: Data, access: LinkDoorMemberAccess) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let profiles = object["profiles"] as? [[String: Any]] else { return nil }
        let kept: [[String: Any]] = profiles.compactMap { profile in
            guard let name = profile["name"] as? String, access.allows(profile: name) else { return nil }
            return profile.filter { profileFields.contains($0.key) }
        }
        return try? JSONSerialization.data(withJSONObject: ["profiles": kept], options: [.sortedKeys])
    }

    static let profileFields: Set<String> = ["name", "display_name", "bot_title", "description", "model", "provider", "is_default"]

    /// One row of the member's chat list, from Hermes's answer for that chat.
    static func chatRow(_ row: [String: Any], profile: String) -> [String: Any] {
        var kept = row.filter { chatFields.contains($0.key) }
        kept["profile"] = profile
        return kept
    }

    static let chatFields: Set<String> = ["id", "title", "started_at", "ended_at", "last_active", "message_count", "preview",
                                          "archived", "pinned", "model", "source", "is_active", "parent_session_id"]
}

/// What one member may reach right now: read fresh for every request, so a change or a Private
/// mark applies at once.
struct LinkDoorMemberAccess: Sendable {
    var device: UUID
    var person: String
    var helpers: Set<String>
    /// The Private list from the add-on; nil when it couldn't be read, and then nothing passes.
    var privateNames: Set<String>?
    var chats: Set<LinkDoorDevices.Chat>
    var small: Bool
    var smallKinds: Set<String> = LinkDoorFamily.smallKinds

    init(device: UUID, member: LinkDoorDevices.Member, privateNames: Set<String>?) {
        self.device = device
        person = member.person
        helpers = Set(member.helpers)
        self.privateNames = privateNames
        chats = Set(member.chats)
        small = member.small
    }

    func allows(profile: String) -> Bool {
        guard helpers.contains(profile), let privateNames else { return false }
        return !LinkDoorFamily.isPrivate(profile, list: privateNames)
    }

    func owns(_ chat: LinkDoorDevices.Chat) -> Bool { allows(profile: chat.profile) && chats.contains(chat) }
}

/// One ask from a member, waiting on the owner.
struct LinkDoorAsk: Equatable, Sendable {
    /// Hermes's request id for the card (`srq-…`), or the approval's own id when it came from a snapshot.
    let id: String
    /// The approval queue's id, which `approval.respond` takes.
    let approvalID: String
    let device: UUID
    let person: String
    let profile: String
    /// The chat's stored id.
    let chat: String
    /// What Hermes said about it, as it sent it to the member (the command already redacted by Hermes).
    let request: Data
    let small: Bool
    let at: Date

    func json() -> [String: Any] {
        var object: [String: Any] = ["id": id, "person": person, "helper": profile, "chat": chat, "small": small,
                                     "at": at.timeIntervalSince1970]
        object["request"] = (try? JSONSerialization.jsonObject(with: request)) ?? [String: Any]()
        return object
    }
}

/// Asks from members, until someone answers them or Hermes withdraws them. Kept in memory only:
/// a helper restart forgets them, and Hermes's own timeout then denies them.
final class LinkDoorAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [LinkDoorAsk] = []
    static let maximum = 64

    var all: [LinkDoorAsk] { lock.withLock { asks } }

    func add(_ ask: LinkDoorAsk) {
        lock.withLock {
            guard !asks.contains(where: { $0.approvalID == ask.approvalID && $0.device == ask.device }) else { return }
            asks.append(ask)
            if asks.count > Self.maximum { asks.removeFirst(asks.count - Self.maximum) }
        }
    }

    /// Takes an ask out by its id or its approval id; returns it when it was there.
    @discardableResult
    func remove(_ id: String) -> LinkDoorAsk? {
        lock.withLock {
            guard let index = asks.firstIndex(where: { $0.id == id || $0.approvalID == id }) else { return nil }
            return asks.remove(at: index)
        }
    }

    func find(_ id: String) -> LinkDoorAsk? { lock.withLock { asks.first { $0.id == id || $0.approvalID == id } } }

    /// Everything one member left open, taken out (they were removed).
    func removeAll(for device: UUID) -> [LinkDoorAsk] {
        lock.withLock {
            let theirs = asks.filter { $0.device == device }
            asks.removeAll { $0.device == device }
            return theirs
        }
    }
}

/// A member's chat socket, both ways. Every message the phone sends is checked against what this
/// member may reach; every message Hermes sends is passed only when it answers this connection's own
/// call or belongs to a chat this connection opened. Lives on the door's queue with its connection.
struct LinkDoorMemberSocket: Sendable {
    enum Call: Equatable, Sendable { case create(String), resume(LinkDoorDevices.Chat), plain }
    struct Request: Equatable, Sendable { let method: String; let sid: String; let approvalID: String; let small: Bool }

    enum Up: Equatable, Sendable {
        case forward
        /// The door's JSON-RPC error, for the phone.
        case refuse(Data)
    }

    enum Effect: Equatable, Sendable {
        /// A chat this member started or resumed, or its new stored id after Hermes compressed it.
        case chat(LinkDoorDevices.Chat)
        case ask(LinkDoorAsk)
        /// An ask answered by the member or withdrawn by Hermes.
        case askGone(String)
    }

    private(set) var calls: [String: Call] = [:]
    /// Runtime session id to the chat it is.
    private(set) var live: [String: LinkDoorDevices.Chat] = [:]
    /// Hermes's open requests on this connection's chats, by request id.
    private(set) var requests: [String: Request] = [:]
    static let maximumCalls = 512

    static let createKeys: Set<String> = ["profile", "cols", "title", "idempotency_key", "close_on_disconnect"]
    static let resumeKeys: Set<String> = ["session_id", "profile", "cols", "lazy", "defer_history", "omit_messages",
                                          "eager_build", "inline_images", "close_on_disconnect"]
    /// Calls on a live chat this connection opened, each with the only parameters it may carry.
    static let chatCalls: [String: Set<String>] = [
        "prompt.submit": ["text", "interrupted", "queued", "surface", "title_preview"],
        "image.attach_bytes": ["content_base64", "data", "filename", "ext"],
        "session.interrupt": ["expected_hosted_task_id"],
        "session.steer": ["text"],
        "session.title": ["title"],
        "session.usage": [], "session.close": [],
        "session.events.since": ["last_seen"],
        "approval.pending": [], "approval.received": ["request_id"],
        "approval.respond": ["choice", "request_id"],
    ]
    /// Session-less events a member's phone still needs.
    static let globalEvents: Set<String> = ["gateway.ready"]

    // MARK: Phone to Hermes

    mutating func up(_ text: Data, access: LinkDoorMemberAccess) -> (Up, [Effect]) {
        guard let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else { return (.refuse(LinkDoorRPC.error(id: nil)), []) }
        let id = object["id"]
        guard id == nil || id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
            return (.refuse(LinkDoorRPC.error(id: nil)), [])
        }
        let refuse = Up.refuse(LinkDoorRPC.error(id: id))
        guard let method = object["method"] else { return answer(object, id: id, access: access) }
        guard let name = method as? String, Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              let params = (object["params"] ?? [String: Any]()) as? [String: Any] else { return (refuse, []) }
        let key = id.map(Self.key)
        if key != nil, calls.count >= Self.maximumCalls { return (refuse, []) }

        switch name {
        case "ping", "client.capabilities":
            if let key { calls[key] = .plain }
            return (.forward, [])
        case "session.create":
            guard let key, Set(params.keys).isSubset(of: Self.createKeys), let profile = params["profile"] as? String,
                  access.allows(profile: profile) else { return (refuse, []) }
            calls[key] = .create(profile)
            return (.forward, [])
        case "session.resume":
            guard let key, Set(params.keys).isSubset(of: Self.resumeKeys), let stored = params["session_id"] as? String,
                  let profile = params["profile"] as? String, access.owns(.init(id: stored, profile: profile)) else { return (refuse, []) }
            calls[key] = .resume(.init(id: stored, profile: profile))
            return (.forward, [])
        default:
            guard let allowed = Self.chatCalls[name], Set(params.keys).isSubset(of: allowed.union(["session_id", "profile"])),
                  let sid = params["session_id"] as? String, let chat = live[sid], access.allows(profile: chat.profile),
                  (params["profile"] as? String).map({ $0 == chat.profile }) ?? (params["profile"] == nil) else { return (refuse, []) }
            if name == "prompt.submit", !(params["text"] is String) { return (refuse, []) }
            var effects: [Effect] = []
            if name == "approval.respond" {
                guard let approvalID = params["request_id"] as? String, !approvalID.isEmpty,
                      let request = requests.first(where: { $0.value.approvalID == approvalID && $0.value.sid == sid }),
                      mayAnswer(choice: params["choice"] as? String, request.value, access: access) else { return (refuse, []) }
                requests[request.key] = nil
                effects.append(.askGone(request.key))
            }
            if let key { calls[key] = .plain }
            return (.forward, effects)
        }
    }

    /// The phone answering one of Hermes's own requests (an approval card, a question).
    private mutating func answer(_ object: [String: Any], id: Any?, access: LinkDoorMemberAccess) -> (Up, [Effect]) {
        let refuse = Up.refuse(LinkDoorRPC.error(id: id))
        guard let id = id as? String, let request = requests[id], Set(object.keys).isSubset(of: ["jsonrpc", "id", "result", "error"]),
              (object["result"] != nil) != (object["error"] != nil) else { return (refuse, []) }
        switch request.method {
        case "clarify":
            requests[id] = nil
            return (.forward, [])
        case "approval":
            guard let result = object["result"] as? [String: Any], Set(result.keys) == ["choice"],
                  mayAnswer(choice: result["choice"] as? String, request, access: access) else { return (refuse, []) }
            requests[id] = nil
            return (.forward, [.askGone(id)])
        default:
            return (refuse, [])
        }
    }

    /// Never mind always; Allow once only for a small ask, with Small yeses on. Never Session or Always.
    private func mayAnswer(choice: String?, _ request: Request, access: LinkDoorMemberAccess) -> Bool {
        switch choice {
        case "deny": true
        case "once": access.small && request.small
        default: false
        }
    }

    // MARK: Hermes to phone

    /// Whether a message from Hermes reaches the member's phone, and what the door learned from it.
    mutating func down(_ text: Data, access: LinkDoorMemberAccess, now: Date = Date()) -> (forward: Bool, effects: [Effect]) {
        guard let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else { return (false, []) }
        let params = object["params"] as? [String: Any] ?? [:]
        if let method = object["method"] as? String {
            let sid = params["session_id"] as? String ?? ""
            if method == "event" {
                if sid.isEmpty { return (Self.globalEvents.contains(params["type"] as? String ?? ""), []) }
                // A helper taken away or marked Private stops at once, mid-chat too.
                guard let chat = live[sid], access.allows(profile: chat.profile) else { return (false, []) }
                var effects = learnStored(sid: sid, from: params["payload"])
                if params["type"] as? String == "request.cancel", let payload = params["payload"] as? [String: Any],
                   let request = payload["id"] as? String, requests.removeValue(forKey: request) != nil {
                    effects.append(.askGone(request))
                }
                return (true, effects)
            }
            // Hermes asking the phone something about one of this connection's chats.
            guard let request = object["id"] as? String, let chat = live[sid], access.allows(profile: chat.profile) else { return (false, []) }
            switch method {
            case "clarify":
                requests[request] = Request(method: method, sid: sid, approvalID: "", small: false)
                return (true, [])
            case "approval":
                guard let ask = makeAsk(id: request, params: params, sid: sid, chat: chat, access: access, now: now) else { return (false, []) }
                return (true, [.ask(ask)])
            default:
                return (false, [])
            }
        }
        // An answer: only to a call this connection made.
        guard let id = object["id"], !(id is NSNull), let call = calls.removeValue(forKey: Self.key(id)) else { return (false, []) }
        guard let result = object["result"] as? [String: Any] else { return (true, []) }
        var effects: [Effect] = []
        switch call {
        case .create(let profile):
            if let sid = result["session_id"] as? String, !sid.isEmpty {
                let stored = (result["stored_session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sid
                guard LinkDoorFamily.validChatID(stored) else { return (true, []) }
                let chat = LinkDoorDevices.Chat(id: stored, profile: profile)
                live[sid] = chat
                effects.append(.chat(chat))
            }
        case .resume(let chat):
            if let sid = result["session_id"] as? String, !sid.isEmpty {
                live[sid] = chat
                effects += learnStored(sid: sid, from: result)
            }
        case .plain:
            break
        }
        // Questions still waiting from before this connection: a snapshot carries them.
        for entry in (result["open_requests"] as? [[String: Any]]) ?? [] {
            guard let request = entry["id"] as? String, let method = entry["method"] as? String,
                  let inner = entry["params"] as? [String: Any], let sid = inner["session_id"] as? String, let chat = live[sid] else { continue }
            if method == "approval", let ask = makeAsk(id: request, params: inner, sid: sid, chat: chat, access: access, now: now) {
                effects.append(.ask(ask))
            } else if method == "clarify" {
                requests[request] = Request(method: method, sid: sid, approvalID: "", small: false)
            }
        }
        return (true, effects)
    }

    private mutating func makeAsk(id: String, params: [String: Any], sid: String, chat: LinkDoorDevices.Chat,
                                  access: LinkDoorMemberAccess, now: Date) -> LinkDoorAsk? {
        guard LinkDoorFamily.validAskID(id) else { return nil }
        let approvalID = (params["request_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let small = LinkDoorFamily.isSmall(params, kinds: access.smallKinds)
        requests[id] = Request(method: "approval", sid: sid, approvalID: approvalID, small: small)
        var shown = params
        shown["session_id"] = nil
        if let command = shown["command"] as? String, command.utf8.count > 4096 { shown["command"] = String(command.prefix(4000)) + "…" }
        let data = (try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys])) ?? Data("{}".utf8)
        return LinkDoorAsk(id: id, approvalID: approvalID, device: access.device, person: access.person, profile: chat.profile,
                           chat: chat.id, request: data.count <= 16_384 ? data : Data("{}".utf8), small: small, at: now)
    }

    /// Hermes moved a chat to a new stored id: the member may open it by that id too.
    private mutating func learnStored(sid: String, from value: Any?) -> [Effect] {
        guard let chat = live[sid], let object = value as? [String: Any], let stored = object["stored_session_id"] as? String,
              stored != chat.id, LinkDoorFamily.validChatID(stored) else { return [] }
        let moved = LinkDoorDevices.Chat(id: stored, profile: chat.profile)
        live[sid] = moved
        return [.chat(moved)]
    }

    static func key(_ id: Any) -> String {
        if let text = id as? String { return "s:" + text }
        if let number = id as? NSNumber { return "n:" + number.stringValue }
        return "?"
    }
}
#endif
