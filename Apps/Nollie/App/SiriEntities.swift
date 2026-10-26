import AppIntents
import CoreSpotlight
import Foundation
import NollieCore

// MARK: What Siri can name while the app is closed
//
// Siri resolves bots and chats by name even when the app is not running, so we maintain a
// compact list as we go: each bot's id and label, and recent chats with id, title and bot
// (never message text). Chat titles are also handed to Spotlight when that option is enabled.

enum SiriCatalog {
    static let botsKey = "siri.bots"
    static let chatsKey = "siri.chats"
    /// Controls Spotlight chat listings. Default is on for iPhone and iPad but off for Mac, where machines are often shared.
    static let spotlightKey = "siri.spotlightChats"
    /// "Answer approvals by voice". Always off until the person turns it on.
    static let approvalsKey = "siri.answersApprovals"
    static let chatLimit = 50

    static var spotlightDefault: Bool { !DeviceWords.isMac }

    private static func flag(_ key: String, fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }

    private static func setFlag(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }

    static var spotlightOn: Bool {
        get { flag(spotlightKey, fallback: spotlightDefault) }
        set { setFlag(spotlightKey, newValue) }
    }

    static var answersApprovals: Bool {
        get { flag(approvalsKey, fallback: false) }
        set { setFlag(approvalsKey, newValue) }
    }

    // Each list is stored as rows of strings: [id, label] for bots, [id, title, bot] for chats.

    private static func rows(_ key: String, width: Int) -> [[String]] {
        let stored = UserDefaults.standard.array(forKey: key) as? [[String]] ?? []
        return stored.filter { $0.count == width }
    }

    static func rememberBots(_ profiles: [ProfileInfo]) {
        let table = profiles.map { [$0.name, $0.label] }
        guard table != rows(botsKey, width: 2) else { return }
        UserDefaults.standard.set(table, forKey: botsKey)
        // Phrases that name a helper ("Ask Scout in Nollie") learn the new names.
        NollieShortcuts.updateAppShortcutParameters()
    }

    static func bots() -> [BotEntity] {
        rows(botsKey, width: 2).map { BotEntity(id: $0[0], label: $0[1]) }
    }

    /// Stores the recent chats, most recent first, and brings Spotlight in line.
    static func rememberChats(_ sessions: [StoredSession]) {
        let table = sessions.prefix(chatLimit).map { session in
            [session.id, session.displayTitle, session.profile ?? ""]
        }
        UserDefaults.standard.set(table, forKey: chatsKey)
        Task { await syncSpotlight() }
    }

    static func chats() -> [ChatEntity] {
        rows(chatsKey, width: 3).map { row in
            ChatEntity(id: row[0], title: row[1], bot: row[2].isEmpty ? nil : row[2])
        }
    }

    /// Brings Spotlight in line with the option: chat titles indexed when enabled, removed when not.
    static func syncSpotlight() async {
        let index = CSSearchableIndex.default()
        guard spotlightOn else {
            try? await index.deleteAppEntities(ofType: ChatEntity.self)
            return
        }
        try? await index.indexAppEntities(chats())
    }

    /// Resolves the bot a request means: whichever was named, then the default bot, then the current one.
    @MainActor static func profile(for bot: BotEntity?, on runtime: GatewayRuntime) -> String? {
        bot?.id ?? runtime.defaultProfile ?? runtime.selectedProfile
    }
}

/// How Siri lists and matches a bot.
struct BotEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Bot" }
    static var defaultQuery: BotQuery { BotQuery() }

    let id: String
    let label: String

    var displayRepresentation: DisplayRepresentation {
        .init(title: LocalizedStringResource(stringLiteral: label))
    }
}

struct BotQuery: EntityQuery, EntityStringQuery {
    func suggestedEntities() async throws -> [BotEntity] {
        return SiriCatalog.bots()
    }

    func entities(for identifiers: [String]) async throws -> [BotEntity] {
        let wanted = Set(identifiers)
        return SiriCatalog.bots().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [BotEntity] {
        SiriCatalog.bots().filter { bot in
            bot.id.localizedCaseInsensitiveContains(string) || bot.label.localizedCaseInsensitiveContains(string)
        }
    }
}

/// A recent chat Siri can find by title; it also appears in Spotlight if that option is enabled.
struct ChatEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Chat" }
    static var defaultQuery: ChatQuery { ChatQuery() }

    let id: String
    let title: String
    let bot: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle = bot.map { LocalizedStringResource(stringLiteral: $0) }
        return .init(title: LocalizedStringResource(stringLiteral: title), subtitle: subtitle)
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = bot.map { "Chat with \($0) in Nollie" } ?? "Chat in Nollie"
        return attributes
    }
}

struct ChatQuery: EntityQuery, EntityStringQuery {
    func suggestedEntities() async throws -> [ChatEntity] {
        return Array(SiriCatalog.chats().prefix(10))
    }

    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        let wanted = Set(identifiers)
        return SiriCatalog.chats().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        SiriCatalog.chats().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
}

/// A spoken yes or no to an approval.
enum ApprovalAnswer: String, AppEnum {
    case approve, deny

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Answer" }
    static var caseDisplayRepresentations: [ApprovalAnswer: DisplayRepresentation] {
        [.approve: "Approve", .deny: "Deny"]
    }
}

/// What Siri says about a bot's status and about an approval. Pure functions, so tests can check them.
enum SiriWords {
    /// For example "Scout is working on a draft. You have one approval to look at."
    static func status(running: [(bot: String, title: String)], waiting: Int, bot: String?) -> String {
        let relevant = bot.map { name in running.filter { $0.bot.lowercased() == name.lowercased() } } ?? running

        let activity: String
        if relevant.isEmpty {
            activity = bot.map { "\($0) is not running anything." } ?? "No bot is running anything."
        } else if let only = relevant.first, relevant.count == 1 {
            activity = "\(only.bot) is working on \(only.title)."
        } else {
            let sample = relevant.prefix(3).map { "\($0.bot) on \($0.title)" }
            activity = "\(relevant.count) chats are running: " + sample.joined(separator: ", ") + "."
        }

        let waitingLine: String? = switch waiting {
        case ..<1: nil
        case 1: "You have one approval to look at."
        default: "You have \(waiting) approvals to look at."
        }
        return [activity, waitingLine].compactMap { $0 }.joined(separator: " ")
    }

    /// Spoken before an answer is taken, like "Scout wants to run ls. Approve it?" For
    /// plugin rules (Ask first, or a sign-in) the readable description is voiced rather than the
    /// gateway's "(plugin approval rule)" stand-in.
    static func approvalQuestion(bot: String, request: ApprovalRequest, answer: ApprovalAnswer) -> String {
        let verb = answer == .approve ? "Approve" : "Deny"
        let isRule = request.patternKey?.hasPrefix("plugin_rule:") == true

        if isRule {
            let words = AskFirstAsk(request)?.summary ?? request.description ?? ""
            let headline = words.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let cleaned = headline.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":.")))
            return "\(bot) asks: " + shortened(cleaned.isEmpty ? "something" : cleaned) + ". \(verb) it?"
        }
        let command = (request.command ?? request.description ?? request.toolName ?? "a command")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(bot) wants to run: " + shortened(command) + ". \(verb) it?"
    }

    /// What Siri says instead of approving when the answer belongs on the screen. A sign-in
    /// needs Face ID or Touch ID, and an Ask first request must be read in full. Nil means Siri
    /// may approve. Denying is always allowed.
    static func approveRefusal(_ request: ApprovalRequest?) -> String? {
        if SignInAsk(request) != nil {
            return "Sign-ins need Face ID or Touch ID. Open Nollie to allow it."
        }
        let askFirstRule = request?.patternKey?.hasPrefix(AskFirstAsk.rulePrefix) ?? false
        if askFirstRule || AskFirstAsk(request) != nil {
            return "This one needs a look first. Open Nollie to answer it."
        }
        return nil
    }

    private static func shortened(_ text: String) -> String {
        text.count <= 120 ? text : text.prefix(119) + "…"
    }
}
