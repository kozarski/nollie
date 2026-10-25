import NollieCore
import SwiftUI

/// The selected card next to the board. Status, bot and priority can be edited right there. Beneath:
/// description, result and child tasks, runs and the worker's log, comments with a field for a new one,
/// and the history. While a worker is on the card it refreshes every few seconds.
struct MacTaskInspector: View {
    let taskID: String
    let store: KanbanStore?
    let onClose: () -> Void
    let onOpenChat: (KanbanTask) -> Void

    init(taskID: String, store: KanbanStore?, onClose: @escaping () -> Void, onOpenChat: @escaping (KanbanTask) -> Void) {
        self.taskID = taskID
        self.store = store
        self.onClose = onClose
        self.onOpenChat = onOpenChat
    }

    @Environment(AppModel.self) private var app
    @State private var inspector = TaskInspectorModel()

    /// Changes when the card or the board changes, which starts the inspector over.
    private struct Subject: Equatable {
        var card: String
        var board: ObjectIdentifier?
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorTitleBar(title: inspector.task?.title, canRename: inspector.task != nil,
                              rename: { new in Task { await inspector.retitle(new) } }, close: onClose)
                .id(taskID)
            Divider()
            content
        }
        .background(Color(.windowBackgroundColor))
        .task(id: Subject(card: taskID, board: store.map(ObjectIdentifier.init))) {
            inspector.show(taskID, in: store)
            await inspector.load()
        }
        // Reloaded after the board is (a move, an event), so this card shows current facts.
        .onChange(of: store?.lastRead) { _, _ in Task { await inspector.load() } }
        .task(id: inspector.task?.isWorking) { await inspector.followWorker() }
        .kanbanAsks(ask: $inspector.ask, answer: $inspector.answer, notice: $inspector.notice) { chosen in
            if await inspector.confirm(chosen) { onClose() }
        }
        .accessibilityIdentifier("board.inspector")
    }

    @ViewBuilder private var content: some View {
        if let info = inspector.detail {
            form(info)
        } else if let problem = inspector.loadProblem {
            ContentUnavailableView("Could not read the task", systemImage: "exclamationmark.triangle",
                                   description: Text(problem))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(_ info: KanbanTaskDetail) -> some View {
        let task = info.task
        return Form {
            TaskFactsSection(
                task: task,
                bots: inspector.candidates(gatewayBots: (app.runtime?.profiles ?? []).map(\.name)),
                setStatus: { status in Task { await inspector.move(to: status) } },
                setBot: { bot in Task { await inspector.give(to: bot) } },
                setPriority: { level in Task { await inspector.prioritise(level) } })
            TaskActionsSection(task: task, discuss: { onOpenChat(task) }, stop: { inspector.ask = .stop(task) })
            TaskWarningsSection(lines: task.warnings.map(\.text))
            TaskDescriptionSection(text: task.body) { words in Task { await inspector.rewrite(words) } }
            TaskOutcomeSection(result: task.result, latestSummary: task.latestSummary, children: info.childResults ?? [])
            TaskRunsSection(taskID: task.id, runs: info.runs, working: task.isWorking)
            TaskCommentsSection(comments: info.comments, working: task.isWorking) { await inspector.post($0) }
            TaskHistorySection(events: info.events)
        }
        .formStyle(.grouped)
    }
}
