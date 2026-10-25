import Foundation
import NollieCore

/// A local reminder of the task that led to a conversation. It never becomes a sent message.
struct BoardChatContext: Hashable, Sendable {
    let connectionID: UUID
    let board: String?
    let boardName: String
    let sessionID: String
    let taskID: String
    let title: String
    let status: String
    let reason: String?

    init?(task: KanbanTask, connectionID: UUID, board: String?, boardName: String?) {
        guard let session = task.sessionId, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.connectionID = connectionID
        self.board = board
        self.boardName = boardName.flatMap { $0.isEmpty ? nil : $0 } ?? "Board"
        sessionID = session
        taskID = task.id
        title = task.title
        status = task.status
        let candidates = task.column == .blocked
            ? [task.lastFailureError, task.warnings.first?.text, task.latestSummary, task.body]
            : [task.latestSummary, task.lastFailureError, task.warnings.first?.text, task.body]
        let text = candidates
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let line = text?.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            reason = trimmed.count > 240 ? String(trimmed.prefix(239)) + "…" : trimmed
        } else { reason = nil }
    }

    var statusTitle: String { KanbanStatus(rawValue: status)?.title ?? status }

    func matches(connectionID: UUID, sessionID: String) -> Bool {
        self.connectionID == connectionID && self.sessionID == sessionID
    }

    var route: PendingRoute {
        // The assignee may differ from the owner of the chat the task came from.
        var route = PendingRoute(connectionID: connectionID, storedSessionID: sessionID)
        route.token = UUID()
        return route
    }
}
