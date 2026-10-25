import Foundation
import NollieCore

/// Which chats the Chats list shows, and in what order. Pure, so it needs no view.
struct SessionListRules {
    var pinnedOnly = false
    var needsYouOnly = false
    var liveOnly = false
    var archivedShown = true
    var runsShown = false
    /// "recent", "title", "bot" or "model".
    var sort = "recent"

    /// A scheduled run's own session (source cron, or a cron id) or a card worker's (its first
    /// message starts "work kanban task"): work the bot did, whose results reach the main chat.
    static func isWork(_ session: StoredSession) -> Bool {
        let source = (session.source ?? "").lowercased()
        return source == "cron" || session.id.hasPrefix("cron_") || (session.preview ?? "").hasPrefix("work kanban task")
    }

    /// The rows that pass every switched-on filter, in order. Each scheduled run and card worker
    /// is a session of its own and their results reach the main chat, so they stay out unless
    /// asked for. So do the bots' Bot Chats: a bot's main chat is the card on top.
    @MainActor func shown(_ rows: [StoredSession], runtime: GatewayRuntime) -> [StoredSession] {
        var keepers: [(StoredSession) -> Bool] = []
        if pinnedOnly { keepers.append { $0.pinned == true } }
        if needsYouOnly { keepers.append { runtime.needsAttention.contains($0.id) } }
        if liveOnly { keepers.append { runtime.chatForStored($0.id)?.isRunning == true } }
        if !archivedShown { keepers.append { $0.archived != true } }
        if !runsShown { keepers.append { !Self.isWork($0) && !MainChatCard.isMainTitle($0.title) } }
        return rows.filter { row in keepers.allSatisfy { $0(row) } }.sorted(by: comesFirst)
    }

    private func stamp(_ session: StoredSession) -> Double { session.lastActive ?? session.startedAt ?? 0 }

    /// The text a non-recent sort compares.
    private func word(_ session: StoredSession) -> String {
        switch sort {
        case "title": session.displayTitle
        case "bot": session.profile ?? ""
        case "model": session.model?.components(separatedBy: "/").last ?? ""
        default: ""
        }
    }

    /// Pinned chats lead in every ordering. In each group the selected key sorts, and ties
    /// go to the most recent first, because the sort is not stable by itself.
    func comesFirst(_ a: StoredSession, _ b: StoredSession) -> Bool {
        let (pinnedA, pinnedB) = (a.pinned == true, b.pinned == true)
        if pinnedA != pinnedB { return pinnedA }
        if sort == "recent" { return stamp(a) > stamp(b) }
        switch word(a).localizedCaseInsensitiveCompare(word(b)) {
        case .orderedSame: return stamp(a) > stamp(b)
        case let order: return order == .orderedAscending
        }
    }
}
