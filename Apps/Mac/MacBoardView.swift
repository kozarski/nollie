import AppKit
import NollieCore
import SwiftUI

/// The Board page: lanes of cards on the left, the chosen card's details on the right.
/// The lanes, cards and status strip are their own views in `MacBoardLanes.swift`; the arrow-key
/// arithmetic and the confirmed changes live in `MacBoardCursor.swift`.
struct MacBoardView: View {
    static let columnWidth: CGFloat = 292
    static let inspectorWidth: CGFloat = 360

    @Environment(AppModel.self) private var model
    @AppStorage("kanban.column") private var requestedColumn = KanbanStatus.ready.rawValue

    @State private var commands = BoardCommands.shared
    @State private var chosen: String?
    @State private var sheet: TaskSheet?
    @State private var addingTask = false
    @State private var dialog = Dialog()
    @State private var revealLane: KanbanPresentationGroup?
    @State private var keys: BoardKeys?

    private struct TaskSheet: Identifiable { let id: String }

    /// The question being asked, the text typed for it, and a notice to show after a failure.
    private struct Dialog {
        var ask: KanbanAsk?
        var answer = ""
        var notice: String?
    }

    /// A board handed in directly, for previews and tests that draw one without a gateway.
    private let handedIn: KanbanStore?

    init(store: KanbanStore? = nil, initialSelection: String? = nil) {
        self._chosen = .init(initialValue: initialSelection)
        self.handedIn = store
    }

    private var store: KanbanStore? { handedIn ?? model.runtime?.kanban }
    private var visible: Bool { handedIn != nil || model.selectedTab == .kanban }
    private var usable: Bool { store?.isPresent == true }

    var body: some View {
        content
            .navigationTitle("Board")
            .toolbar { toolbar }
            .task(id: visible) { await store?.keepReading(whileVisible: visible) }
            .onChange(of: visible, initial: true) { _, on in watchKeys(on) }
            .onDisappear { watchKeys(false) }
            .onChange(of: chosen) { commands.selectedID = chosen }
            .onChange(of: store?.selectedBoard) { _, _ in chosen = nil }
            .onChange(of: store?.lastRead) { _, _ in revealReturnedCard() }
            .onChange(of: model.boardTaskToReveal, initial: true) { _, _ in revealReturnedCard() }
            .onChange(of: requestedColumn, initial: true) { _, _ in applyRequestedColumn() }
            .onChange(of: commands.newTaskRequest) { _, _ in
                if visible && usable { addingTask = true }
            }
            .onChange(of: commands.openRequest) { _, _ in
                if visible, let id = chosen { sheet = TaskSheet(id: id) }
            }
            .sheet(isPresented: $addingTask) {
                KanbanNewTaskSheet { warning in dialog.notice = warning ?? dialog.notice }
                    .sheetFrame()
                    .withAppModel()
            }
            .sheet(item: $sheet) { target in
                KanbanTaskSheet(taskID: target.id) { task in
                    sheet = nil
                    openChat(of: task)
                }
                .sheetFrame(.wide)
                .withAppModel()
            }
            .kanbanAsks(ask: $dialog.ask, answer: $dialog.answer, notice: $dialog.notice) { await confirm($0) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let store {
            if store.effective == .absent {
                BoardEmpty.pluginOff.view
            } else if let board = store.board {
                boardWithDetails(board, in: store)
            } else if let problem = store.lastError, !store.loading {
                BoardEmpty.unreadable(problem).view
            } else {
                ProgressView("Reading the board…")
            }
        } else {
            BoardEmpty.noGateway.view
        }
    }

    private func boardWithDetails(_ board: KanbanBoard, in store: KanbanStore) -> some View {
        let payload = BoardDragPayload(gateway: model.runtime?.connection.id.uuidString ?? "",
                                       board: store.selectedBoard ?? "")
        return HStack(spacing: 0) {
            BoardLanes(board: board, selection: chosen, reveal: $revealLane,
                       onDrop: { dropped($0, onto: $1, store: store, payload: payload) }) { task in
                BoardCardButton(task: task, chosen: task.id == chosen, dragID: payload.encode(task.id),
                                choose: { chosen = task.id }) {
                    MacCardMenu(task: task, store: store, ask: $dialog.ask, notice: $dialog.notice,
                                onOpen: { chosen = task.id; sheet = TaskSheet(id: task.id) },
                                onOpenChat: openChat(of:))
                }
            }
            detailsPanel(for: board, in: store)
        }
        .safeAreaInset(edge: .bottom, spacing: 0, content: { BoardStatusBar(store: store) })
    }

    /// The chosen card's details, with a rule between them and the lanes. Nothing when no card is chosen.
    @ViewBuilder private func detailsPanel(for board: KanbanBoard, in store: KanbanStore) -> some View {
        if let card = chosen.flatMap({ board.task(id: $0) }) {
            Divider()
            MacTaskInspector(taskID: card.id, store: store, onClose: { chosen = nil }, onOpenChat: openChat(of:))
                .frame(width: Self.inspectorWidth)
        }
    }

    // MARK: Toolbar

    private var toolbarOptions: [BoardToolbar.BoardOption] {
        [
            .init(title: String(localized: "About the Board badge"), symbol: "info.circle") {
                dialog.notice = String(localized: "The blue badge counts tasks that need your help. The agents handle routine reviews.")
            },
            .init(title: String(localized: "Refresh"), symbol: "arrow.clockwise") { Task { await store?.refresh() } },
            .init(title: String(localized: "Check for tasks"), symbol: "play.circle") { Task { await store?.nudge() } },
        ]
    }

    private var toolbar: some ToolbarContent {
        BoardToolbar(store: store, pickBoard: { slug in
            chosen = nil
            store?.select(board: slug)
        }, options: toolbarOptions, addTask: { addingTask = true })
    }

    // MARK: Changes

    private func openChat(of task: KanbanTask) {
        model.openBoardChat(task, board: store?.selectedBoard, boardName: store?.selectedBoardMeta?.displayName)
    }

    /// A card dropped on a lane. Blocking and finishing ask first; anything else moves at once.
    private func dropped(_ items: [String], onto lane: KanbanPresentationGroup,
                         store: KanbanStore, payload: BoardDragPayload) -> Bool {
        guard items.count == 1, let board = store.board,
              let id = payload.taskID(in: items[0]), let task = board.task(id: id),
              !lane.tasks(in: board).contains(where: { $0.id == id }) else { return false }
        switch lane {
        case .blocked: dialog.ask = .block(task)
        case .done: dialog.ask = .done(task)
        case .pending:
            Task { if await !store.move(task, to: lane.moveTarget) { dialog.notice = store.lastError ?? dialog.notice } }
        }
        return true
    }

    /// Runs what the person confirmed, with whatever they typed in the box.
    private func confirm(_ question: KanbanAsk) async {
        guard let store else { return }
        let typed = dialog.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        dialog.answer = ""
        dialog.ask = nil
        if case .delete(let task) = question, chosen == task.id { chosen = nil }
        guard let accepted = await store.carryOut(question, typed: typed) else { return }
        if !accepted { dialog.notice = store.lastError ?? dialog.notice }
    }

    // MARK: Keys and requests

    private func watchKeys(_ on: Bool) {
        keys?.remove()
        keys = on ? BoardKeys { press($0) } : nil
    }

    private func press(_ key: BoardKey) -> Bool {
        switch key {
        case .return:
            guard let id = chosen else { return false }
            sheet = TaskSheet(id: id)
        case .delete:
            guard let id = chosen, let task = store?.board?.task(id: id) else { return false }
            dialog.ask = .delete(task)
        case .escape:
            guard chosen != nil else { return false }
            chosen = nil
        default:
            guard let board = store?.board,
                  let next = BoardCursor(board: board, current: chosen).target(for: key) else { return false }
            chosen = next
        }
        return true
    }

    /// The Blocked lane, when something asked to land there (a tap on the Board badge).
    private func applyRequestedColumn() {
        guard visible, requestedColumn == KanbanStatus.review.rawValue else { return }
        revealLane = .blocked
        requestedColumn = KanbanStatus.ready.rawValue
    }

    /// Selects the card the person has come back to from its chat, or says it is gone.
    private func revealReturnedCard() {
        guard visible, let context = model.boardTaskToReveal,
              context.connectionID == model.runtime?.connection.id,
              context.board == store?.selectedBoard, let board = store?.board else { return }
        model.boardTaskToReveal = nil
        if board.task(id: context.taskID) == nil {
            dialog.notice = String(localized: "This task is no longer on the board.")
        } else {
            chosen = context.taskID
        }
    }
}

typealias BoardKey = BoardKeys.Key
