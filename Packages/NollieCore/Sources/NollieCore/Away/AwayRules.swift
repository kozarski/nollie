import Foundation

/// What a phone may ask for through iCloud, and for how long anything in the mailbox is good.
/// The same spirit as the Link door's allowlist: a few things the phone needs away, nothing else.
public enum AwayRules {
    /// How long each note is good for, from when it was written.
    public static let sendLife: TimeInterval = 15 * 60
    public static let stopLife: TimeInterval = 10 * 60
    public static let statusLife: TimeInterval = 2 * 60
    /// An approval card, and so the answer to it.
    public static let cardLife: TimeInterval = 10 * 60
    public static let replyLife: TimeInterval = 24 * 3600
    public static let noticeLife: TimeInterval = 60 * 60
    /// A clock this far ahead is still believed.
    public static let skew: TimeInterval = 5 * 60

    public static let maximumText = 8_000
    public static let maximumReply = 32_000
    /// Approval words as the phone shows them.
    public static let maximumCardText = 4_000

    /// The only answers a phone may give: a yes for this one action, or no.
    public static let awayChoices = ["once", "deny"]

    public static func life(of note: AwayNote) -> TimeInterval {
        switch note {
        case .send: sendLife
        case .answer, .card: cardLife
        case .stop: stopLife
        case .status: statusLife
        case .reply: replyLife
        case .received, .closed, .stopped, .helpers, .refused: noticeLife
        }
    }

    /// True while a letter is good: written no later than a little ahead of now, not yet expired,
    /// and not given a longer life than its kind allows.
    public static func isFresh(_ letter: AwayLetter, expiresAt: Date, now: Date) -> Bool {
        letter.at <= now.addingTimeInterval(skew)
            && expiresAt > now
            && expiresAt.timeIntervalSince(letter.at) <= life(of: letter.note) + 1
            && expiresAt > letter.at
    }

    /// Nil when the Mac may act on this note from a phone; otherwise why not. `isPrivate` answers
    /// for the Mac's own Private list, read fresh.
    public static func refusal(for note: AwayNote, isPrivate: (String) -> Bool) -> AwayRefusal? {
        switch note {
        case .send(let bot, let chat, let text):
            guard isBotName(bot) else { return .unknownBot }
            guard !isPrivate(bot.lowercased()) else { return .privateBot }
            if let chat, !isChatID(chat) { return .unknownChat }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .empty }
            // Slash commands run Hermes's full command line: they stay on the Mac.
            guard !trimmed.hasPrefix("/") else { return .slashCommand }
            guard text.count <= maximumText else { return .tooLong }
            guard isPlain(text) else { return .notAllowed }
            return nil
        case .answer(let card, let choice):
            guard isCardID(card) else { return .unknownCard }
            guard awayChoices.contains(choice) else { return .notAllowed }
            return nil
        case .stop, .status:
            return nil
        default:
            // A Mac's kind of note never comes from a phone.
            return .notAllowed
        }
    }

    /// A Mac's note the phone will show: right shapes and sizes, choices only once and deny.
    public static func acceptsFromMac(_ note: AwayNote) -> Bool {
        switch note {
        case .received(let request, let chat):
            return AwayHeader.isValidID(request) && chat.map(isChatID) != false
        case .reply(let request, let bot, let chat, let text):
            return AwayHeader.isValidID(request) && isBotName(bot) && isChatID(chat) && text.count <= maximumReply
        case .card(let card, let request, let bot, let chat, let approval, _):
            let words = [approval.command, approval.description, approval.toolName, approval.patternKey].compactMap { $0 }
            return isCardID(card) && AwayHeader.isValidID(request) && isBotName(bot) && isChatID(chat)
                && !approval.choices.isEmpty && approval.choices.allSatisfy(awayChoices.contains)
                && Set(approval.choices).count == approval.choices.count
                && words.allSatisfy { $0.count <= maximumCardText }
        case .closed(let card, _):
            return isCardID(card)
        case .stopped(let request, let paused):
            return AwayHeader.isValidID(request) && paused >= 0 && paused < 10_000
        case .helpers(let request, let helpers):
            return request.map(AwayHeader.isValidID) != false && helpers.count <= 64
                && helpers.allSatisfy { isBotName($0.bot) && !$0.name.isEmpty && $0.name.count <= 64 && $0.waiting < 1_000 }
        case .refused(let request, _):
            return AwayHeader.isValidID(request)
        case .send, .answer, .stop, .status:
            return false
        }
    }

    /// The choices a card may offer away: Allow once and Deny, and only when Hermes offers both.
    /// Nil means the card is answered on the Mac.
    public static func choices(offered: [String]) -> [String]? {
        let allowed = awayChoices.filter(offered.contains)
        return allowed == awayChoices ? allowed : nil
    }

    // MARK: Shapes

    /// A bot is a Hermes profile name: letters, digits, `-` and `_`, never "all".
    public static func isBotName(_ name: String) -> Bool {
        isIdentifier(name, maximum: 64) && name.lowercased() != "all"
    }

    public static func isChatID(_ id: String) -> Bool { isIdentifier(id, maximum: 255) }

    /// `ac_` and 32 lowercase hex, made by the Mac when it sends a card.
    public static func isCardID(_ id: String) -> Bool {
        id.utf8.count == 35 && id.hasPrefix("ac_") && id.utf8.dropFirst(3).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func newCardID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "ac_" + AwayTag.hex(Data(bytes))
    }

    static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Words, new lines and tabs. No other control characters and no direction overrides, which
    /// could make a message read differently on the Mac than it was written.
    static func isPlain(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            // Control characters only: emoji joiners and other format characters are fine.
            if scalar.properties.generalCategory == .control { return false }
            return !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
        }
    }
}
