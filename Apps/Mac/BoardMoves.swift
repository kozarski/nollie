import NollieCore

/// Rules the Board's card menu and inspector share, kept as plain functions.
extension KanbanAsk {
    /// The question a move to this status has to answer first (a note, or a yes), if there is one.
    static func gate(_ task: KanbanTask, movingTo status: KanbanStatus) -> KanbanAsk? {
        switch status {
        case .done: .done(task)
        case .blocked: .block(task)
        case .archived: .archive(task)
        default: nil
        }
    }
}

extension KanbanStore {
    /// Carries out a question the person confirmed, with what they typed. Nil means nothing was
    /// asked of the gateway (a comment with no words); otherwise whether it went through.
    func carryOut(_ confirmed: KanbanAsk, typed: String) async -> Bool? {
        switch confirmed {
        case .done(let task): await move(task, to: .done, summary: typed)
        case .block(let task): await move(task, to: .blocked, blockReason: typed)
        case .comment(let task): typed.isEmpty ? nil : await comment(task, typed)
        case .archive(let task): await move(task, to: .archived)
        case .delete(let task): await delete(task)
        case .stop(let task): await stop(task, reason: "stopped from Nollie")
        }
    }
}
