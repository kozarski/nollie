import Foundation
import QuartzCore
import NollieCore

/// One entry of the conversation list: a row of the transcript, a card the add-on posted, a question the bot waits
/// on, or the short line that says what it is doing. Equatable on what it draws, so the list redraws only entries
/// that changed.
enum ConversationListItem: Equatable, Identifiable {
    case row(ConversationRow, startsTurn: Bool)
    /// A post's row, with the runs the person opened up: a card that grows changes its item, so it is measured again.
    case post(ConversationRow, expanded: Set<String>)
    case card(ConversationCard)
    case activity(String)

    var id: String {
        switch self {
        case .row(let row, _), .post(let row, _): row.id
        case .card(let card): "card:\(card.id)"
        case .activity: "activity"
        }
    }

    /// Entries of one kind share cells and a sizer, so a reused cell keeps the same view structure.
    var kind: String {
        switch self {
        case .row(let row, _), .post(let row, _):
            switch row.kind {
            case .user: "user"
            case .assistant: "bot"
            case .tool: "tool"
            case .note: "note"
            case .error: "error"
            case .post(let post):
                switch post.kind {
                case .nightShift: "nightShift"
                case .rehearsal: "rehearsal"
                }
            }
        case .card: "card"
        case .activity: "activity"
        }
    }

    static let kinds = ["user", "bot", "tool", "note", "error", "card", "activity", "nightShift", "rehearsal"]

    var row: ConversationRow? {
        switch self {
        case .row(let row, _), .post(let row, _): row
        case .card, .activity: nil
        }
    }

    /// The transcript, then (only while the window touches the newest end) the cards and the activity line.
    /// `expanded` holds `<post id>/<run id>` for each run whose actions are all shown.
    static func make(transcript: [ConversationRow], cards: [ConversationCard], activity: String?,
                     atNewestEnd: Bool, expanded: Set<String> = []) -> [ConversationListItem] {
        var out: [ConversationListItem] = []
        out.reserveCapacity(transcript.count + cards.count + 1)
        var previousWasYours = true
        // A list needs each id once; a row the engine gave twice is drawn the first time.
        var seen = Set<String>()
        for row in transcript where seen.insert(row.id).inserted {
            if let post = row.post {
                let runs = post.nightShift?.runs.map(\.id).filter { expanded.contains(expandedKey(post: post.id, run: $0)) } ?? []
                out.append(.post(row, expanded: Set(runs)))
                previousWasYours = false
                continue
            }
            let yours = row.userText != nil
            out.append(.row(row, startsTurn: yours && !previousWasYours && !out.isEmpty))
            previousWasYours = yours
        }
        guard atNewestEnd else { return out }
        out.append(contentsOf: cards.filter { seen.insert("card:\($0.id)").inserted }.map { .card($0) })
        if let activity { out.append(.activity(activity)) }
        return out
    }

    static func expandedKey(post: String, run: String) -> String { "\(post)/\(run)" }
}

/// What changed between two lists of entries: the new order, and entries that stayed but draw differently.
struct ConversationListChange: Equatable {
    var ids: [String]
    var changed: [String]
    /// Only entries changed: nothing came or went.
    var sameOrder: Bool

    init(from old: [ConversationListItem], to new: [ConversationListItem]) {
        ids = new.map(\.id)
        sameOrder = ids == old.map(\.id)
        var before: [String: ConversationListItem] = [:]
        before.reserveCapacity(old.count)
        for item in old { before[item.id] = item }
        changed = new.compactMap { item in
            guard let was = before[item.id], was != item else { return nil }
            return item.id
        }
    }

    var isEmpty: Bool { sameOrder && changed.isEmpty }
}

#if DEBUG
/// Main-thread time the list spends, for the measuring tests (`conversation.metrics`).
@MainActor
enum ConversationListTiming {
    static var measureMs = 0.0
    static var measured = 0
    static var updateMs = 0.0
    static var updates = 0
    static var longestUpdateMs = 0.0
    /// The list is dragged or coasts.
    static var moving = false

    static var line: String {
        "measurems=\(Int(measureMs)) measured=\(measured) updatems=\(Int(updateMs)) updates=\(updates) longestupdatems=\(Int(longestUpdateMs))"
    }

    static func time<T>(_ add: (Double) -> Void, _ work: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = work()
        add((CACurrentMediaTime() - start) * 1000)
        return result
    }
}
#endif
