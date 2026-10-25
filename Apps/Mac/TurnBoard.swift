import AppKit
import NollieCore

/// Everything the Mac is occupied with, in one list: turns underway and approvals that need the
/// person. The status item in the menu bar lists these, and the Dock tile counts the ones awaiting a reply.
@MainActor
@Observable
final class TurnBoard {
    static let shared = TurnBoard()

    struct Turn: Identifiable {
        let id: String
        let startedAt: Date
        var title: String
        var bot: String
        var profile: String
        var detail: String
        var attention: Bool
        weak var chat: ChatSession?

        init(id: String, title: String, bot: String, profile: String, detail: String,
             attention: Bool, startedAt: Date, chat: ChatSession? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.title = title
            self.bot = bot
            self.profile = profile
            self.detail = detail
            self.attention = attention
            self.chat = chat
        }
    }

    private(set) var turns = [Turn]()

    var running: Int { turns.count(where: { !$0.attention }) }
    var attention: Int { turns.count(where: \.attention) }

    /// Approvals the menu bar may refuse but never grant. An Ask first hold has to be read in
    /// full on its card, and a saved sign-in needs Touch ID.
    nonisolated static func answersInApp(_ approval: ApprovalRequest) -> Bool {
        let reserved = [AskFirstAsk.rulePrefix, SignInAsk.rulePrefix]
        return approval.patternKey.map { key in reserved.contains(where: key.hasPrefix) } ?? false
    }

    func upsert(_ turn: Turn) {
        switch turns.firstIndex(where: { $0.id == turn.id }) {
        case let slot?: turns[slot] = turn
        case nil: turns.append(turn)
        }
        showIndicators()
    }

    func remove(_ id: String) {
        turns.removeAll { $0.id == id }
        showIndicators()
    }

    private func showIndicators() {
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
        // Idle bots only play with their eyes while something is working (#248).
        let anyoneBusy = !turns.isEmpty
        guard BotAmbient.shared.anyWorking != anyoneBusy else { return }
        BotAmbient.shared.anyWorking = anyoneBusy
    }
}
