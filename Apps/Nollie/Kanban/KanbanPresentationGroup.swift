import NollieCore

/// Three user-facing lanes retain the gateway's detailed lifecycle underneath.
enum KanbanPresentationGroup: String, CaseIterable, Identifiable, Sendable, Hashable {
    case pending, blocked, done
    var id: String { rawValue }
    var title: String {
        switch self { case .pending: "Pending"; case .blocked: "Blocked"; case .done: "Done" }
    }
    var symbol: String {
        switch self { case .pending: "clock"; case .blocked: "hand.raised"; case .done: "checkmark.circle" }
    }
    var description: String {
        switch self {
        case .pending: "Working, checking or planned for later."
        case .blocked: "Needs your help to move forward."
        case .done: "Finished and ready to revisit."
        }
    }
    var statuses: [KanbanStatus] {
        switch self {
        case .pending: [.running, .review, .ready, .todo, .triage, .scheduled, .blocked]
        case .blocked: [.blocked]
        case .done: [.done]
        }
    }
    var moveTarget: KanbanStatus {
        switch self { case .pending: .todo; case .blocked: .blocked; case .done: .done }
    }
    func tasks(in board: KanbanBoard) -> [KanbanTask] {
        var seen = Set<String>()
        var tasks = statuses.flatMap { status in
            board.allTasks.filter { $0.column == status && Self.group(for: $0) == self && seen.insert($0.id).inserted }
        }
        if self == .pending {
            tasks += board.allTasks.filter { $0.column == nil && seen.insert($0.id).inserted }
        }
        return tasks
    }
    static func group(for status: KanbanStatus) -> Self? {
        if status == .archived { return nil }
        if status == .done { return .done }
        if status == .blocked { return .blocked }
        return .pending
    }
    static func group(for task: KanbanTask) -> Self? {
        if task.column == .archived { return nil }
        if task.column == .done { return .done }
        return task.needsUserAction ? .blocked : .pending
    }
}
