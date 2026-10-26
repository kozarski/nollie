import Foundation

/// What a helper remembers about the person, from its Hermes memory files.
///
/// Hermes keeps two lists in each bot's home: `USER.md` (who the person is) and `MEMORY.md` (the
/// bot's own notes). The workflow add-on serves them at `/api/plugins/nollie-workflow/memory`, and
/// every change goes through it: it takes Hermes's own lock, reads the file again, and changes exactly
/// the entry the person saw. An edit to an entry Hermes has changed meanwhile comes back as
/// `HelperMemoryError.changed`, never written over it. Nothing is kept on the device.
public enum HelperMemoryKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// `USER.md`: what it knows about the person.
    case user
    /// `MEMORY.md`: notes it keeps for itself.
    case memory

    public var id: String { rawValue }
}

/// One remembered thing, exactly as Hermes stores it.
public struct HelperMemoryEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String

    public init(id: String? = nil, text: String) {
        self.id = id ?? text
        self.text = text
    }
}

/// One of the two lists: its entries oldest first (Hermes adds at the end), and how full it is.
public struct HelperMemoryList: Codable, Equatable, Sendable {
    public var entries: [HelperMemoryEntry]
    public var used: Int
    public var limit: Int

    public init(entries: [HelperMemoryEntry] = [], used: Int = 0, limit: Int = 1) {
        self.entries = entries
        self.used = used
        self.limit = limit
    }

    /// Newest first, as the person reads it.
    public var newestFirst: [HelperMemoryEntry] { entries.reversed() }
}

/// A helper's memory as the add-on answers: the two lists, whether Hermes uses memory for it, and an
/// outside memory service if one is set (what that keeps is not shown here).
public struct HelperMemory: Codable, Equatable, Sendable {
    public var bot: String
    public var on: Bool
    public var provider: String
    public var stores: [String: HelperMemoryList]

    public init(bot: String, on: Bool = true, provider: String = "", user: [String] = [], memory: [String] = []) {
        self.bot = bot
        self.on = on
        self.provider = provider
        stores = [HelperMemoryKind.user.rawValue: HelperMemoryList(entries: user.map { HelperMemoryEntry(text: $0) }),
                  HelperMemoryKind.memory.rawValue: HelperMemoryList(entries: memory.map { HelperMemoryEntry(text: $0) })]
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bot = try values.decode(String.self, forKey: .bot)
        on = try values.decodeIfPresent(Bool.self, forKey: .on) ?? true
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? ""
        stores = try values.decodeIfPresent([String: HelperMemoryList].self, forKey: .stores) ?? [:]
    }

    public func list(_ kind: HelperMemoryKind) -> HelperMemoryList { stores[kind.rawValue] ?? HelperMemoryList() }

    public var isEmpty: Bool { HelperMemoryKind.allCases.allSatisfy { list($0).entries.isEmpty } }

    public var count: Int { HelperMemoryKind.allCases.reduce(0) { $0 + list($1).entries.count } }

    /// Whether this exact entry is still in that list.
    public func contains(_ text: String, in kind: HelperMemoryKind) -> Bool { list(kind).entries.contains { $0.text == text } }
}

public enum HelperMemoryError: Error, Equatable, Sendable {
    /// The entry changed or went on the Mac since it was read.
    case changed
    /// Hermes would not keep it (empty, too long, memory full, words that steer the agent): the add-on's words.
    case refused(String)
    /// This gateway has no memory routes (an older add-on), or the bot is gone.
    case unavailable
    /// A private bot, seen from somewhere it isn't shown.
    case privateBot
}

/// Where a bot's memory may be shown. Moss and every bot named private: never. Another bot on the
/// Private list: only in Nollie on the Mac that runs its Hermes. Everyone else: here.
public enum HelperMemoryAccess: Equatable, Sendable {
    case shown
    /// A private bot, on the Mac that keeps its memory.
    case shownOnThisMac
    case hidden

    public static func decide(bot: String, isPrivate: Bool, onThisMac: Bool) -> HelperMemoryAccess {
        if namesCarriedOverPrivateBot(bot) { return .hidden }
        if isPrivate { return onThisMac ? .shownOnThisMac : .hidden }
        return .shown
    }

    /// True when the name, or any word in it, is `private` or `moss`: the bots Nollie never reads.
    public static func namesCarriedOverPrivateBot(_ bot: String) -> Bool {
        let name = bot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let words = [name] + name.components(separatedBy: letters.union(CharacterSet(charactersIn: "_-")).inverted)
            + name.components(separatedBy: letters.inverted)
        return words.contains { $0 == "private" || $0 == "moss" }
    }
}

private struct MemoryNoteBody: Encodable, Sendable { var target: String; var text: String }
private struct MemoryEditBody: Encodable, Sendable { var target: String; var old: String; var text: String }
private struct MemoryForgetBody: Encodable, Sendable { var target: String; var old: String }
private struct MemorySwitchBody: Encodable, Sendable { var on: Bool }

@MainActor
extension GatewayRuntime {
    public static let memoryPath = "/api/plugins/nollie-workflow/memory"

    /// `bot`, and `on_this_mac` only when Nollie on the Mac that runs this Hermes asks for a private bot.
    /// The Link door lets nothing but `bot` through on these routes.
    static func memoryQuery(bot: String, onThisMac: Bool) -> [URLQueryItem] {
        [URLQueryItem(name: "bot", value: bot)] + (onThisMac ? [URLQueryItem(name: "on_this_mac", value: "true")] : [])
    }

    public func helperMemory(bot: String, onThisMac: Bool = false) async throws -> HelperMemory {
        try await memoryCall { try await self.api.get(Self.memoryPath, query: Self.memoryQuery(bot: bot, onThisMac: onThisMac)) }
    }

    public func rememberForHelper(_ text: String, kind: HelperMemoryKind = .user, bot: String, onThisMac: Bool = false) async throws -> HelperMemory {
        try await memoryCall {
            try await self.api.send("POST", Self.memoryPath + "/notes", query: Self.memoryQuery(bot: bot, onThisMac: onThisMac),
                                    body: MemoryNoteBody(target: kind.rawValue, text: text))
        }
    }

    public func editHelperMemory(_ old: String, to text: String, kind: HelperMemoryKind, bot: String, onThisMac: Bool = false) async throws -> HelperMemory {
        try await memoryCall {
            try await self.api.send("PUT", Self.memoryPath + "/notes", query: Self.memoryQuery(bot: bot, onThisMac: onThisMac),
                                    body: MemoryEditBody(target: kind.rawValue, old: old, text: text))
        }
    }

    public func forgetHelperMemory(_ old: String, kind: HelperMemoryKind, bot: String, onThisMac: Bool = false) async throws -> HelperMemory {
        try await memoryCall {
            try await self.api.send("DELETE", Self.memoryPath + "/notes", query: Self.memoryQuery(bot: bot, onThisMac: onThisMac),
                                    body: MemoryForgetBody(target: kind.rawValue, old: old))
        }
    }

    public func setHelperMemory(on: Bool, bot: String, onThisMac: Bool = false) async throws -> HelperMemory {
        try await memoryCall {
            try await self.api.send("PUT", Self.memoryPath + "/switch", query: Self.memoryQuery(bot: bot, onThisMac: onThisMac),
                                    body: MemorySwitchBody(on: on))
        }
    }

    private func memoryCall(_ call: () async throws -> HelperMemory) async throws -> HelperMemory {
        do {
            return try await call()
        } catch HermesAPIError.http(status: 409, _) {
            throw HelperMemoryError.changed
        } catch HermesAPIError.http(status: 422, let words) {
            throw HelperMemoryError.refused(words)
        } catch HermesAPIError.http(status: 404, _) {
            throw HelperMemoryError.unavailable
        } catch HermesAPIError.http(status: 403, _) {
            throw HelperMemoryError.privateBot
        }
    }
}
