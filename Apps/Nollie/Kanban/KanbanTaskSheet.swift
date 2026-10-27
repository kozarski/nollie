import NollieCore
import SwiftUI

/// What the task sheet holds on to between reads, and the changes it can make through the
/// board's store. Each change reads the task again when it goes through.
@MainActor @Observable
final class TaskSheetState {
    let taskID: String
    private(set) var detail: KanbanTaskDetail?
    var problem: String?
    var comment = ""
    private(set) var sending = false

    init(taskID: String) { self.taskID = taskID }

    var task: KanbanTask? { detail?.task }

    func reload(_ store: KanbanStore?) async {
        guard let store else { return }
        do {
            detail = try await store.detail(taskID)
            problem = nil
        } catch {
            problem = KanbanStore.message(error)
        }
    }

    /// Reads once, and while a worker is on the task reads again every few seconds, because its
    /// runs and heartbeat change.
    func follow(_ store: KanbanStore?) async {
        await reload(store)
        if task?.isWorking == true { await repeatEvery(6) { await reload(store) } }
    }

    /// Runs one change; on failure the store's own words are shown.
    private func change(_ store: KanbanStore?, _ attempt: (KanbanStore, KanbanTask) async -> Bool) async {
        guard let store, let task else { return }
        if await attempt(store, task) { await reload(store) } else { problem = store.lastError }
    }

    func stopWorker(_ store: KanbanStore?) async {
        guard let store, let task else { return }
        // The reason goes to the gateway, so it stays in English.
        if await store.stop(task, reason: "stopped from Nollie") == false { problem = store.lastError }
        await reload(store)
    }

    func sendComment(_ store: KanbanStore?) async {
        let words = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return }
        sending = true
        defer { sending = false }
        await change(store) { store, task in
            let taken = await store.comment(task, words)
            if taken { self.comment = "" }
            return taken
        }
    }

    func rename(to proposed: String, _ store: KanbanStore?) async {
        let title = proposed.trimmingCharacters(in: .whitespaces)
        guard let current = task?.title, !title.isEmpty, title != current else { return }
        await change(store) { store, task in await store.edit(task, title: title, body: nil) }
    }

    /// Moves the task to a status that needs nothing more from the person.
    func move(to status: KanbanStatus, _ store: KanbanStore?) async {
        await change(store) { store, task in await store.move(task, to: status) }
    }

    /// A move or change the person confirmed with its note or yes.
    func carryOut(_ ask: KanbanAsk, typed: String, _ store: KanbanStore?) async {
        guard let store else { return }
        guard let accepted = await store.carryOut(ask, typed: typed) else { return }
        if accepted { await reload(store) } else { problem = store.lastError }
    }

    func describe(as text: String, _ store: KanbanStore?) async {
        guard text != (task?.body ?? "") else { return }
        await change(store) { store, task in await store.edit(task, title: nil, body: text) }
    }
}

/// One task in full: its facts, description, result, comments (with a box to add one), worker
/// runs and log, and history. The title and description can be edited here.
struct KanbanTaskSheet: View {
    var taskID: String
    var onOpenChat: (KanbanTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var state: TaskSheetState
    @State private var question: Question?
    @State private var titleDraft = ""
    @State private var bodyDraft = ""
    @State private var editingBody = false
    /// A move that needs a note or a yes first (Done, Block, Archive).
    @State private var boardQuestion: KanbanAsk?
    @State private var reply = ""

    /// The small questions the sheet can ask.
    private enum Question { case rename, stopWorker }

    init(taskID: String, onOpenChat: @escaping (KanbanTask) -> Void) {
        self.taskID = taskID
        self.onOpenChat = onOpenChat
        _state = State(initialValue: TaskSheetState(taskID: taskID))
    }

    private var store: KanbanStore? { model.runtime?.kanban }

    /// A run's length in words: seconds, minutes, or hours and minutes.
    static func duration(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: String(localized: "\(seconds)s", comment: "A run's length in seconds, short")
        case ..<3600: String(localized: "\(seconds / 60) min", comment: "A run's length in minutes, short")
        default: String(localized: "\(seconds / 3600) h \((seconds % 3600) / 60) min", comment: "A run's length in hours and minutes, short")
        }
    }

    var body: some View {
        NavigationStack {
            page
                .inlineTitle(.verbatim(state.task?.title ?? String(localized: "Task", comment: "A Board task; a title")))
                .toolbar { toolbar }
                .alert("Rename", isPresented: isAsking(.rename)) {
                    TextField("Title", text: $titleDraft)
                    Button("Save") { Task { await state.rename(to: titleDraft, store) } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog(
                    "Stop the worker?", isPresented: isAsking(.stopWorker), titleVisibility: .visible,
                    actions: {
                        Button("Cancel", role: .cancel) {}
                        Button("Stop", role: .destructive) { Task { await state.stopWorker(store) } }
                    },
                    message: { Text("The worker stops and the card returns to Ready.") })
                .modifier(BoardQuestions(question: $boardQuestion, reply: $reply, settle: { ask in
                    let typed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    (boardQuestion, reply) = (nil, "")
                    Task { await state.carryOut(ask, typed: typed, store) }
                }))
                // A refused comment or stop while the task is showing: say so.
                .noticeAlert(LocalizedStringResource("Board", comment: "The Board, Nollie's task board; a name"), $state.problem, showing: state.detail != nil)
                // The board was fetched again (after a move or an event), so refresh the task too.
                .onChange(of: store?.lastRead) { Task { await state.reload(store) } }
                .task(id: state.task?.isWorking) { await state.follow(store) }
        }
    }

    @ViewBuilder private var page: some View {
        if let detail = state.detail {
            TaskSections(
                detail: detail, editing: $editingBody, draft: $bodyDraft, openChat: onOpenChat,
                saveDescription: {
                    editingBody = false
                    Task { await state.describe(as: bodyDraft, store) }
                },
                comment: CommentBox(text: $state.comment, busy: state.sending) {
                    Task { await state.sendComment(store) }
                })
        } else if let problem = state.problem {
            Placeholder(LocalizedStringResource("Could not read the task"), symbol: "exclamationmark.triangle", detail: .verbatim(problem))
        } else {
            ProgressView()
        }
    }

    private func isAsking(_ which: Question) -> Binding<Bool> {
        Binding(get: { question == which }, set: { if !$0 && question == which { question = nil } })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        if let task = state.task {
            ToolbarItemGroup(placement: .primaryAction) {
                moveMenu(for: task)
                editMenu(for: task)
                if task.isWorking {
                    Button("Stop the Worker", systemImage: "stop.circle") { question = .stopWorker }
                }
            }
        }
    }

    /// Where the card can go, as the Board's long press offers it. Done, Block and Archive ask first.
    private func moveMenu(for task: KanbanTask) -> some View {
        Menu {
            ForEach(KanbanAsk.moveTargets(from: task.column), id: \.self) { status in
                Button(status.title, systemImage: status.symbol) {
                    if let ask = KanbanAsk.gate(task, movingTo: status) {
                        boardQuestion = ask
                    } else {
                        Task { await state.move(to: status, store) }
                    }
                }
                .testID("task.move." + status.rawValue)
            }
        } label: {
            Label("Move", systemImage: "arrow.right.square")
        }
        .testID("task.move")
    }

    private func editMenu(for task: KanbanTask) -> some View {
        Menu {
            Button("Rename…", systemImage: "pencil") {
                titleDraft = task.title
                question = .rename
            }
            Button(task.body?.isEmpty == false ? "Edit the Description" : "Add a Description", systemImage: "text.alignleft") {
                bodyDraft = task.body ?? ""
                editingBody = true
            }
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        .testID("task.edit")
    }
}

// MARK: - The sections

/// The sheet's list, top to bottom. The drafts live in the sheet and come in as bindings.
private struct TaskSections: View {
    let detail: KanbanTaskDetail
    @Binding var editing: Bool
    @Binding var draft: String
    let openChat: (KanbanTask) -> Void
    let saveDescription: () -> Void
    let comment: CommentBox

    var body: some View {
        let task = detail.task
        List {
            TaskFacts(task: task, openChat: openChat)
            if !task.warnings.isEmpty { warnings(task) }
            descriptionSection(task)
            outcome(task)
            if let children = detail.childResults, !children.isEmpty {
                Section("Children") { ForEach(children) { ChildResultRow(child: $0) } }
            }
            runsSection(task)
            Section("Comments") {
                ForEach(detail.comments) { CommentRow(note: $0) }
                comment
            }
            if !detail.events.isEmpty { history }
        }
    }

    private func warnings(_ task: KanbanTask) -> some View {
        Section("Needs a look") {
            ForEach(task.warnings.indices, id: \.self) { index in
                Label(task.warnings[index].text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func descriptionSection(_ task: KanbanTask) -> some View {
        Section("Task") {
            if editing {
                DescriptionEditor(draft: $draft, cancel: { editing = false }, save: saveDescription)
            } else if let text = task.body, !text.isEmpty {
                MarkdownView(text: text)
            } else {
                Text("No description yet.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func outcome(_ task: KanbanTask) -> some View {
        if let text = task.result ?? task.latestSummary, !text.isEmpty {
            Section(task.result == nil ? "Latest summary" : "Result") {
                Text(text).textSelection(.enabled)
            }
        }
    }

    private func runsSection(_ task: KanbanTask) -> some View {
        Section("Runs") {
            if detail.runs.isEmpty { Text("No worker has taken it yet.").foregroundStyle(.secondary) }
            ForEach(detail.runs.reversed()) { RunRow(run: $0) }
            NavigationLink(destination: KanbanLogView(taskID: task.id, live: task.isWorking)) {
                Label("Worker log", systemImage: "doc.plaintext")
            }
        }
    }

    private var history: some View {
        Section("History") {
            ForEach(detail.events.suffix(12).reversed()) { event in
                HStack {
                    Text(event.line).font(.caption)
                    Spacer()
                    Ago(date: event.created)
                }
            }
        }
    }
}

/// The box for editing a task's description, with Cancel and Save under it.
private struct DescriptionEditor: View {
    @Binding var draft: String
    var cancel: () -> Void
    var save: () -> Void

    var body: some View {
        TextEditor(text: $draft)
            .accessibilityLabel("Description")
            .frame(minHeight: 120)
            .font(.body)
        // Bordered styles: plain buttons in a list row both fire when the row is tapped.
        HStack(spacing: 8) {
            Button("Cancel", action: cancel).buttonStyle(.bordered)
            Button("Save", action: save).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// "3 minutes ago", small and faint.
private struct Ago: View {
    let date: Date
    var body: some View {
        Text(date, format: .relative(presentation: .named)).small(.caption2, .tertiary)
    }
}

/// Status, bot, priority and the rest of a task's facts, with a way into its chat.
private struct TaskFacts: View {
    let task: KanbanTask
    let openChat: (KanbanTask) -> Void

    var body: some View {
        Section {
            // Use plain views for the value slot. A Label here made the row grow to the full screen height.
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: task.column?.symbol ?? "circle")
                    Text(task.column?.title ?? task.status)
                }
            }
            LabeledContent("Bot") { holder }
            LabeledContent("Priority", value: KanbanView.priorityName(task.priority ?? 0))
            if let made = task.created {
                LabeledContent("Made") { Text(made, format: .relative(presentation: .named)) }
            }
            if let tenant = task.tenant, !tenant.isEmpty { LabeledContent("Tenant", value: tenant) }
            if task.sessionId?.isEmpty == false {
                Button { openChat(task) } label: {
                    Label("Discuss task", systemImage: "bubble.left.and.bubble.right")
                }
                .testID("task.openChat")
            }
        }
    }

    @ViewBuilder private var holder: some View {
        if let name = task.assignee, !name.isEmpty {
            HStack(spacing: 6) {
                BotAvatar(profile: name, size: 18, animated: false)
                Text(name)
            }
        } else {
            Text("Unassigned").foregroundStyle(.secondary)
        }
    }
}

private struct ChildResultRow: View {
    let child: KanbanChildResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(child.title, systemImage: KanbanStatus(rawValue: child.status)?.symbol ?? "circle")
            if let text = child.result ?? child.latestSummary { Text(text).small().lineLimit(2) }
        }
    }
}

private struct CommentRow: View {
    let note: KanbanComment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(note.author).font(.caption.weight(.semibold))
                Spacer()
                Ago(date: note.created)
            }
            Text(note.body).font(.subheadline)
        }
    }
}

/// The box that adds a comment, and the arrow that sends it.
private struct CommentBox: View {
    @Binding var text: String
    var busy: Bool
    var send: () -> Void

    var body: some View {
        HStack {
            TextField("Add a comment", text: $text, axis: .vertical).lineLimit(1...4)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .accessibilityLabel("Send the comment")
                .disabled(busy || text.allSatisfy(\.isWhitespace))
        }
    }
}

private struct RunRow: View {
    let run: KanbanRun

    private var timing: String {
        let length = KanbanTaskSheet.duration(run.durationSeconds)
        return "\(run.started.formatted(.relative(presentation: .named))) \u{00B7} \(length)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                who
                Text(timing).small(.caption2, .tertiary)
                remark(run.error, tone: .red, lines: 2)
                remark(run.summary, tone: .secondary, lines: 3)
            }
            Spacer()
            if run.isOpen { ProgressView().controlSize(.small) }
        }
    }

    /// A line the run left behind, if it left one.
    @ViewBuilder private func remark(_ text: String?, tone: TextTone, lines: Int) -> some View {
        if let text, !text.isEmpty { Text(text).small(.caption, tone).lineLimit(lines) }
    }

    private var stateShade: AnyShapeStyle {
        run.isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }

    /// The bot that took the run, if any, and where the run stands.
    private var who: some View {
        HStack(spacing: 6) {
            if let bot = run.profile {
                BotAvatar(profile: bot, size: 16, animated: false)
                Text(bot).font(.subheadline)
            }
            Text(run.stateText).font(.caption).foregroundStyle(stateShade)
        }
    }
}

// MARK: - The worker's log

/// The worker's log as last read, or why it could not be.
@MainActor @Observable
private final class WorkerLog {
    enum Reading { case waiting, empty, text(KanbanLog), problem(String) }
    private(set) var reading = Reading.waiting

    func refresh(_ taskID: String, from store: KanbanStore?) async {
        guard let store else { return }
        do {
            let log = try await store.log(taskID)
            reading = log.exists ? .text(log) : .empty
        } catch {
            // A log already on screen stays; a failed re-read does not blank it.
            if case .text = reading { return }
            reading = .problem(KanbanStore.message(error))
        }
    }
}

/// Worker output and errors; re-fetched every few seconds as long as the task is running.
struct KanbanLogView: View {
    @Environment(AppModel.self) private var model
    @State private var worker = WorkerLog()
    var taskID: String
    var live: Bool

    var body: some View {
        ScrollView { shown }
            .inlineTitle(LocalizedStringResource("Worker log"))
            .task {
                await worker.refresh(taskID, from: model.runtime?.kanban)
                if live { await repeatEvery(4) { await worker.refresh(taskID, from: model.runtime?.kanban) } }
            }
    }

    @ViewBuilder private var shown: some View {
        switch worker.reading {
        case .waiting:
            ProgressView().padding()
        case .empty:
            Placeholder(LocalizedStringResource("No log yet"), symbol: "doc.plaintext", detail: LocalizedStringResource("A log shows up once a worker starts."))
        case .problem(let why):
            Placeholder(LocalizedStringResource("Could not read the log"), symbol: "exclamationmark.triangle", detail: .verbatim(why))
        case .text(let log):
            Text(log.content)
                .textSelection(.enabled)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            if log.truncated == true {
                Text("Only the end of the log is shown.").small(.caption2, .tertiary).inset(h: 16)
            }
        }
    }
}
