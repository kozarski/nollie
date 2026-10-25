import SwiftUI
import NollieCore

/// The Board: the gateway's kanban lanes side by side, each task a card with the gateway's own
/// actions on a swipe, a long press, or in its detail sheet.
struct KanbanView: View {
    /// True when pushed from Settings rather than shown as a tab, where "on screen" simply means
    /// "has appeared".
    var embedded = false

    /// The sheets that can cover the board.
    private enum Cover: Identifiable {
        case task(KanbanTask)
        case newTask

        var id: String {
            switch self {
            case .task(let task): "task-" + task.id
            case .newTask: "new"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("kanban.column") private var requestedColumn = KanbanStatus.ready.rawValue
    @State private var cover: Cover?
    @State private var question: KanbanAsk?
    @State private var reply = ""
    @State private var notice: String?
    @State private var hasAppeared = false
    @State private var lane: String? = KanbanPresentationGroup.pending.rawValue

    private var store: KanbanStore? { model.runtime?.kanban }
    private var isShowing: Bool { embedded ? hasAppeared : model.selectedTab == .kanban }

    var body: some View {
        content
            .inlineTitle("Board")
            .toolbar { toolbar }
            .onAppear {
                hasAppeared = true
                showReturnedTask()
            }
            .onDisappear { hasAppeared = false }
            .onChange(of: store?.lastRead) { showReturnedTask() }
            .onChange(of: model.boardTaskToReveal) { showReturnedTask() }
            .task(id: isShowing) { await keepFresh() }
            .sheet(item: $cover) { sheet(for: $0).withAppModel() }
            .modifier(BoardQuestions(question: $question, reply: $reply, settle: { ask in Task { await settle(ask) } }))
            .noticeAlert("Board", $notice)
    }

    @ViewBuilder private func sheet(for cover: Cover) -> some View {
        switch cover {
        case .task(let task):
            KanbanTaskSheet(taskID: task.id) { chosen in
                self.cover = nil
                discuss(chosen)
            }
            .sheetFrame(.wide)
            .withAppModel()
        case .newTask:
            KanbanNewTaskSheet { warning in
                if let warning { notice = warning }
            }
            .sheetFrame()
            .withAppModel()
        }
    }

    @ViewBuilder private var content: some View {
        if let store {
            switch (store.effective, store.board) {
            case (.absent, _):
                Placeholder("Kanban is off on this gateway", symbol: "rectangle.split.3x1", detail: "Switch on the kanban plugin in the gateway dashboard, under Plugins, and your Board shows up here.")
            case (_, let board?):
                lanes(of: board, in: store)
            case (_, nil):
                if let message = store.lastError, !store.loading {
                    Placeholder("Could not read the board", symbol: "exclamationmark.triangle", detail: message)
                } else {
                    ProgressView("Reading the board…")
                }
            }
        } else {
            Placeholder("No gateway", symbol: "antenna.radiowaves.left.and.right.slash", detail: "Add a gateway in Settings and its board will show here.")
        }
    }

    // MARK: Lanes and cards

    private func lanes(of board: KanbanBoard, in store: KanbanStore) -> some View {
        GeometryReader { space in
            let laneWidth = min(380, space.size.width - 40)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(KanbanPresentationGroup.allCases) { group in
                        let tasks = group.tasks(in: board)
                        BoardLane(group: group, count: tasks.count, onDrop: { receive($0, into: group, store: store) }) {
                            ForEach(tasks) { card($0, store: store) }
                        }
                        .frame(width: laneWidth)
                        .id(group.rawValue)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 16)
                .frame(height: space.size.height)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $lane, anchor: .leading)
            .scrollIndicators(.hidden)
            .onAppear(perform: jumpToRequestedLane)
        }
        .id(store.selectedBoard)
        .testID("board.list")
    }

    /// Something asked to land on the review column; that lane is "blocked" here.
    private func jumpToRequestedLane() {
        guard requestedColumn == KanbanStatus.review.rawValue else { return }
        lane = KanbanPresentationGroup.blocked.rawValue
        requestedColumn = KanbanStatus.ready.rawValue
    }

    /// What a dragged card carries: gateway, board and task, so a drop from elsewhere is ignored.
    private func dragToken(for task: KanbanTask, in store: KanbanStore) -> String {
        [model.runtime?.connection.id.uuidString ?? "", store.selectedBoard ?? "", task.id].joined(separator: "/")
    }

    private func receive(_ items: [String], into group: KanbanPresentationGroup, store: KanbanStore) -> Bool {
        guard let token = items.first, items.count == 1,
              let board = store.board,
              let gateway = model.runtime?.connection.id,
              let boardName = store.selectedBoard
        else { return false }

        let prefix = "\(gateway.uuidString)/\(boardName)/"
        guard token.hasPrefix(prefix),
              let task = board.task(id: String(token.dropFirst(prefix.count))),
              group.tasks(in: board).allSatisfy({ $0.id != task.id })
        else { return false }

        Task { await move(task, to: group.moveTarget, store: store) }
        return true
    }

    private func card(_ task: KanbanTask, store: KanbanStore) -> some View {
        Button { cover = .task(task) } label: {
            BoardTaskRow(task: task)
                .padding(16)
                .nollieGlass(.regular, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .draggable(dragToken(for: task, in: store))
        .testID("board.task.\(task.id)")
        .contextMenu { actions(for: task, store: store) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) { leadingSwipe(task, store) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingSwipe(task) }
    }

    @ViewBuilder private func leadingSwipe(_ task: KanbanTask, _ store: KanbanStore) -> some View {
        if ![.done, .archived].contains(task.column) {
            Button("Done", systemImage: "checkmark") { question = .done(task) }
                .tint(.green)
        }
        if task.column == .blocked {
            Button("Unblock", systemImage: "play") { Task { await move(task, to: .ready, store: store) } }
                .tint(.blue)
        }
    }

    @ViewBuilder private func trailingSwipe(_ task: KanbanTask) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) { question = .delete(task) }
        if task.isWorking {
            Button("Stop", systemImage: "stop.fill") { question = .stop(task) }
                .tint(.orange)
        } else if ![.blocked, .done, .archived].contains(task.column) {
            Button("Block", systemImage: "hand.raised") { question = .block(task) }
                .tint(.orange)
        }
    }

    static func priorityName(_ level: Int) -> String {
        switch level {
        case 0: "Normal"
        case 1: "High"
        case 2: "Urgent"
        default: "Critical"
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let store, store.boards.count > 1 {
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    ForEach(store.boards) { board in
                        Button { store.select(board: board.slug) } label: {
                            let title = menuTitle(for: board, in: store)
                            if board.slug == store.selectedBoard {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                        .testID("board.choose.\(board.slug)")
                    }
                } label: {
                    Label("Board", systemImage: "square.stack")
                }
                .accessibilityLabel("Choose a board")
                .testID("board.choose")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("About the Board badge", systemImage: "info.circle") {
                    notice = "The blue badge counts tasks that need your help. The agents handle routine reviews."
                }
                Button("Check for tasks", systemImage: "play.circle") { Task { await store?.nudge() } }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store?.refresh() } }
            } label: {
                Label("Board options", systemImage: "ellipsis.circle")
            }
            Button("New Task", systemImage: "plus") { cover = .newTask }
                .disabled(store?.isPresent != true)
        }
    }

    private func menuTitle(for board: KanbanBoardMeta, in store: KanbanStore) -> String {
        let summary = BoardReviewSummary(boards: [board], selectedBoard: store.selectedBoard, loadedBoard: store.board)
        let waiting = summary.entries.first(where: { $0.slug == board.slug })?.count ?? 0
        return waiting > 0 ? "\(board.displayName) (\(waiting) needing your help)" : board.displayName
    }

    // MARK: Card actions

    @ViewBuilder private func actions(for task: KanbanTask, store: KanbanStore) -> some View {
        Menu("Move to", systemImage: "arrow.right.square") {
            ForEach(KanbanStatus.allCases.filter { $0 != task.column }, id: \.self) { status in
                if status.isMoveTarget {
                    Button(status.title, systemImage: status.symbol) {
                        Task { await move(task, to: status, store: store) }
                    }
                } else {
                    // A hand cannot put a card here; tapping explains why.
                    Button("\(status.title) (gateway only)", systemImage: status.symbol) {
                        notice = status.notMovableReason
                    }
                }
            }
        }

        Menu("Reassign", systemImage: "person.crop.circle.badge.checkmark") {
            tickable("Unassigned", ticked: task.assignee == nil) {
                Task { await apply(store.reassign(task, to: nil), store) }
            }
            ForEach(store.assignees) { person in
                tickable(person.name, ticked: task.assignee == person.name) {
                    Task { await apply(store.reassign(task, to: person.name), store) }
                }
            }
        }

        Menu("Priority", systemImage: "flag") {
            ForEach(0..<4, id: \.self) { level in
                tickable(Self.priorityName(level), ticked: (task.priority ?? 0) == level) {
                    Task { await apply(store.setPriority(task, level), store) }
                }
            }
        }

        Button("Comment", systemImage: "bubble.left") { question = .comment(task) }
        if task.isWorking {
            Button("Stop the Worker", systemImage: "stop.circle") { question = .stop(task) }
        }
        if task.sessionId?.isEmpty == false {
            Button("Discuss task", systemImage: "bubble.left.and.bubble.right") { discuss(task) }
        }
        Divider()
        if task.column != .archived {
            Button("Archive", systemImage: "archivebox") { question = .archive(task) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { question = .delete(task) }
    }

    /// A menu entry with a tick when it is the current choice.
    @ViewBuilder private func tickable(_ title: String, ticked: Bool, action: @escaping () -> Void) -> some View {
        if ticked {
            Button(title, systemImage: "checkmark", action: action)
        } else {
            Button(title, action: action)
        }
    }

    private func move(_ task: KanbanTask, to status: KanbanStatus, store: KanbanStore) async {
        switch status {
        case .done: question = .done(task)
        case .blocked: question = .block(task)
        case .archived: question = .archive(task)
        default: await apply(store.move(task, to: status), store)
        }
    }

    /// After a write: show the gateway's words if it said no, nothing if it said yes.
    private func apply(_ accepted: Bool, _ store: KanbanStore) async {
        guard !accepted, let message = store.lastError else { return }
        notice = message
    }

    private func settle(_ ask: KanbanAsk) async {
        guard let store else { return }
        let typed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        (question, reply) = (nil, "")
        switch ask {
        case .done(let task): await apply(store.move(task, to: .done, summary: typed), store)
        case .block(let task): await apply(store.move(task, to: .blocked, blockReason: typed), store)
        case .comment(let task): if !typed.isEmpty { await apply(store.comment(task, typed), store) }
        case .archive(let task): await apply(store.move(task, to: .archived), store)
        case .delete(let task): await apply(store.delete(task), store)
        case .stop(let task): await apply(store.stop(task, reason: "stopped from Nollie"), store)
        }
    }

    private func discuss(_ task: KanbanTask) {
        model.openBoardChat(task, board: store?.selectedBoard, boardName: store?.selectedBoardMeta?.displayName)
    }

    /// Opens the task that a notification or link pointed at, once its board is showing.
    private func showReturnedTask() {
        guard isShowing, let target = model.boardTaskToReveal,
              target.connectionID == model.runtime?.connection.id,
              target.board == store?.selectedBoard,
              let board = store?.board
        else { return }
        model.boardTaskToReveal = nil
        if let task = board.task(id: target.taskID) {
            cover = .task(task)
        } else {
            notice = "This task is no longer on the board."
        }
    }

    /// While the page is showing: read now, listen on the live socket, and read again every
    /// minute. When it is hidden, the socket is closed.
    private func keepFresh() async {
        guard let store else { return }
        guard isShowing else { return store.stopEvents() }
        await store.refresh()
        store.startEvents()
        await store.loadAssignees()
        await repeatEvery(60) { await store.refresh() }
    }
}

/// The question put to the person before a board change: a text box for Done, Block and
/// Comment, a plain yes or no for the rest.
private struct BoardQuestions: ViewModifier {
    @Binding var question: KanbanAsk?
    @Binding var reply: String
    let settle: (KanbanAsk) -> Void

    private func showing(text: Bool) -> Binding<Bool> {
        Binding(
            get: { question.map { $0.asksForText == text } ?? false },
            set: { if !$0 { question = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(question?.title ?? "", isPresented: showing(text: true), presenting: question) { ask in
                TextField(ask.placeholder, text: $reply)
                Button(ask.verb) { settle(ask) }
                Button("Cancel", role: .cancel) { (question, reply) = (nil, "") }
            } message: { ask in
                Text(ask.message)
            }
            .confirmationDialog(question?.title ?? "", isPresented: showing(text: false), titleVisibility: .visible, presenting: question) { ask in
                Button(ask.verb, role: ask.destructive ? .destructive : nil) { settle(ask) }
                Button("Cancel", role: .cancel) { (question, reply) = (nil, "") }
            } message: { ask in
                Text(ask.message)
            }
    }
}
