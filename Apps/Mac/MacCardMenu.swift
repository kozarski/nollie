import NollieCore
import SwiftUI

/// What a card's right-click menu can do.
enum CardMenuAction: Hashable {
    case open, comment, unblock, block, finish, stopWorker, discuss, archive, delete

    var title: String {
        switch self {
        case .open: String(localized: "Open", comment: "Board card menu: opens the card")
        case .comment: String(localized: "Comment…", comment: "Board card menu: adds a comment")
        case .unblock: String(localized: "Unblock", comment: "Board card menu")
        case .block: String(localized: "Block…", comment: "Board card menu: marks the task blocked")
        case .finish: String(localized: "Done…", comment: "Board card menu: marks the task done")
        case .stopWorker: String(localized: "Stop the Worker…", comment: "Safety: Board card menu; stops the worker on this task")
        case .discuss: String(localized: "Discuss task")
        case .archive: String(localized: "Archive…", comment: "Board card menu")
        case .delete: String(localized: "Delete…", comment: "Safety: Board card menu; deletes the task")
        }
    }

    var symbol: String {
        switch self {
        case .open: "rectangle.expand.vertical"
        case .comment: "bubble.left"
        case .unblock: "play"
        case .block: "hand.raised"
        case .finish: "checkmark"
        case .stopWorker: "stop.circle"
        case .discuss: "bubble.left.and.bubble.right"
        case .archive: "archivebox"
        case .delete: "trash"
        }
    }
}

/// Which entries a card's menu offers, from the card's state. The phone's menu follows the same rules.
struct CardMenuPlan {
    var workflow: [CardMenuAction] = [.comment]
    var ending: [CardMenuAction] = []

    init(task: KanbanTask) {
        let closed = task.column == .done || task.column == .archived
        let working = task.isWorking

        if task.column == .blocked {
            workflow.append(.unblock)
        } else if !closed && !working {
            workflow.append(.block)
        }
        if !closed { workflow.append(.finish) }
        if working { workflow.append(.stopWorker) }
        if let chat = task.sessionId, !chat.isEmpty { workflow.append(.discuss) }

        if task.column != .archived { ending.append(.archive) }
        ending.append(.delete)
    }
}

/// The right-click menu for a card on the Board.
struct MacCardMenu: View {
    let task: KanbanTask
    let store: KanbanStore
    let onOpen: () -> Void
    let onOpenChat: (KanbanTask) -> Void
    @Binding private var ask: KanbanAsk?
    @Binding private var notice: String?

    init(task: KanbanTask, store: KanbanStore, ask: Binding<KanbanAsk?>, notice: Binding<String?>,
         onOpen: @escaping () -> Void, onOpenChat: @escaping (KanbanTask) -> Void) {
        self.task = task
        self.store = store
        self.onOpen = onOpen
        self.onOpenChat = onOpenChat
        _ask = ask
        _notice = notice
    }

    private var plan: CardMenuPlan { CardMenuPlan(task: task) }

    var body: some View {
        entries([.open])
        Divider()
        moveMenu
        assignMenu
        priorityMenu
        entries(plan.workflow)
        Divider()
        entries(plan.ending)
    }

    private func entries(_ actions: [CardMenuAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button(role: action == .delete ? .destructive : nil) {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
        }
    }

    // MARK: Pickers

    private var moveMenu: some View {
        Menu {
            let others = KanbanStatus.allCases.filter { $0 != task.column }
            ForEach(others, id: \.self) { status in
                Button {
                    if status.isMoveTarget { move(to: status) } else { notice = status.notMovableReason }
                } label: {
                    let name = status.isMoveTarget ? status.title : String(localized: "\(status.title) (gateway only)", comment: "A Board status only the gateway can move a card to")
                    Label(name, systemImage: status.symbol)
                }
            }
        } label: {
            Label("Move to", systemImage: "arrow.right.square")
        }
    }

    private var assignMenu: some View {
        Menu {
            choice(String(localized: "Unassigned", comment: "A Board task with no bot"), current: task.assignee == nil) { change { await store.reassign(task, to: nil) } }
            ForEach(store.assignees) { person in
                choice(person.name, current: task.assignee == person.name) {
                    change { await store.reassign(task, to: person.name) }
                }
            }
        } label: {
            Label("Reassign", systemImage: "person.crop.circle.badge.checkmark")
        }
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(0..<4, id: \.self) { level in
                choice(KanbanView.priorityName(level), current: (task.priority ?? 0) == level) {
                    change { await store.setPriority(task, level) }
                }
            }
        } label: {
            Label("Priority", systemImage: "flag")
        }
    }

    /// A menu line that wears a tick when it is the card's current value.
    private func choice(_ title: String, current: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            if current {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: Doing

    private func perform(_ action: CardMenuAction) {
        switch action {
        case .open: onOpen()
        case .comment: ask = .comment(task)
        case .unblock: move(to: .ready)
        case .block: ask = .block(task)
        case .finish: ask = .done(task)
        case .stopWorker: ask = .stop(task)
        case .discuss: onOpenChat(task)
        case .archive: ask = .archive(task)
        case .delete: ask = .delete(task)
        }
    }

    /// Moves the card, or asks first for the statuses that need a note or a yes.
    private func move(to status: KanbanStatus) {
        if let question = KanbanAsk.gate(task, movingTo: status) {
            ask = question
        } else {
            change { await store.move(task, to: status) }
        }
    }

    /// Runs a store change, and shows the store's reason if it did not go through.
    private func change(_ work: @escaping () async -> Bool) {
        Task {
            if await work() { return }
            if let reason = store.lastError { notice = reason }
        }
    }
}
