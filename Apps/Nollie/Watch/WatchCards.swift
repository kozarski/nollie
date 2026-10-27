#if os(iOS)
import Foundation
import NollieCore

/// Which approvals the Watch may say yes to, and the words it shows for each. Worded here on the
/// phone, from the same pieces the chat's card uses, so the wrist reads what the card reads.
///
/// The Watch can always say no. It says yes only to an ordinary approval: anything that pays,
/// sends or posts (Face ID for buying and sending), a saved sign-in (Face ID on the phone) and a
/// bot asking to use the Mac (System control) wait for the iPhone, and a private bot's words stay
/// on the phone. The phone checks this again when the answer arrives, whatever the Watch sent.
enum WatchCards {
    /// Ask first kinds whose yes needs the person's face or passcode on the phone.
    static let phoneOnlyKinds: Set<AskFirstAsk.Kind> = [.buy, .send, .post]

    /// True when a yes to this approval must be given on the iPhone.
    static func needsPhone(_ approval: ApprovalRequest, privateBot: Bool) -> Bool {
        if privateBot { return true }
        if SignInAsk(approval) != nil { return true }
        if (approval.patternKey ?? "").hasPrefix("cua:") { return true }
        if let ask = AskFirstAsk(approval), phoneOnlyKinds.contains(ask.kind) { return true }
        // An Ask first rule whose words could not be read is judged by its key alone.
        if let kind = askFirstKind(approval.patternKey), phoneOnlyKinds.contains(kind) { return true }
        return false
    }

    /// The kind named in an Ask first rule's key (`plugin_rule:nollie-ask-first:<kind>:<id>`).
    static func askFirstKind(_ key: String?) -> AskFirstAsk.Kind? {
        guard let key, key.hasPrefix(AskFirstAsk.rulePrefix) else { return nil }
        let word = key.dropFirst(AskFirstAsk.rulePrefix.count).split(separator: ":", omittingEmptySubsequences: false).first
        return word.flatMap { AskFirstAsk.Kind(rawValue: String($0)) }
    }

    /// One card for the Watch.
    @MainActor
    static func approval(card: PendingCard, request: ApprovalRequest, chatID: String, profile: String,
                         connectionID: UUID, botName: String, avatar: String, privateBot: Bool,
                         asksAgain: Bool) -> WatchWire.Approval {
        let who = botName.isEmpty ? String(localized: "Your bot", comment: "Stands in for a bot with no name, at the start of a sentence") : botName
        var words = Words(title: String(localized: "\(who) needs your OK", comment: "Safety: an approval on the Watch; keep exact meaning"),
                          body: aboutLine(request), symbol: "checkmark.shield.fill")
        if privateBot {
            // A private bot's request is never shown off the phone.
            words = Words(title: String(localized: "A helper needs your OK", comment: "Safety: an approval on the Watch; keep exact meaning"),
                          body: "", symbol: "lock.fill")
        } else if let ask = SignInAsk(request) {
            words = Words(title: String(localized: "\(who) wants to sign in to \(ask.site)",
                                        comment: "Safety: a sign-in approval on the Watch; the second %@ is a website"),
                          body: "", symbol: "key.fill")
        } else if let ask = AskFirstAsk(request) {
            let card = AskFirstCardBody(ask: ask, botName: botName, onChoice: { _ in })
            words = Words(title: card.title, body: ask.summary, symbol: symbol(for: ask.kind), check: ask.check)
        } else if (request.patternKey ?? "").hasPrefix("cua:") {
            words = Words(title: String(localized: "\(who) wants to use your Mac", comment: "Safety: a Mac control approval on the Watch"), body: ApprovalCardView.screenLine(request.patternKey ?? ""),
                          symbol: "cursorarrow.rays")
        } else if let command = request.command, !command.isEmpty {
            words.command = command
        }
        return WatchWire.Approval(
            id: card.id, requestID: request.requestId, chatID: chatID, profile: profile,
            connectionID: connectionID.uuidString, botName: privateBot ? "" : botName,
            avatar: privateBot ? "" : avatar, symbol: words.symbol, title: words.title, body: words.body,
            check: words.check, command: words.command,
            answers: needsPhone(request, privateBot: privateBot) ? .denyOnly : .allowOrDeny,
            asksAgain: asksAgain, flagged: request.smartDenied == true && !privateBot)
    }

    private struct Words {
        var title: String
        var body: String
        var symbol: String
        var check: String?
        var command: String?
    }

    /// The card's own line for an ordinary approval: the gateway's description, else what kind of
    /// thing it is.
    static func aboutLine(_ request: ApprovalRequest) -> String {
        if let said = request.description, !said.isEmpty { return said }
        if let tool = request.toolName, !tool.isEmpty, tool != "terminal" {
            return String(localized: "Use \(tool.replacingOccurrences(of: "_", with: " ")).",
                          comment: "Safety: what an approval allows; %@ is a tool's name")
        }
        return (request.command ?? "").isEmpty
            ? String(localized: "Go ahead with this.", comment: "Safety: what an approval allows")
            : String(localized: "Run a command.", comment: "Safety: what an approval allows")
    }

    static func symbol(for kind: AskFirstAsk.Kind) -> String {
        switch kind {
        case .send: "paperplane.fill"
        case .buy: "creditcard.fill"
        case .post: "megaphone.fill"
        case .delete: "trash.fill"
        case .unsure: "questionmark.circle.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle.fill"
        }
    }

    // MARK: Checking an answer

    enum Verdict: Equatable {
        case answer(String)
        /// The yes has to come from the phone.
        case refuse(String)
    }

    /// What the phone does with an answer from the Watch, judged on the card as the phone has it.
    static func verdict(_ choice: WatchWire.Choice, request: ApprovalRequest, privateBot: Bool) -> Verdict {
        switch choice {
        case .deny: .answer("deny")
        case .once: needsPhone(request, privateBot: privateBot) ? .refuse(WatchWords.approveOnPhone) : .answer("once")
        }
    }
}
#endif
