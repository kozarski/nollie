import NollieCore
import SwiftUI

// The parts of the Board's inspector, each a small view with its own inputs.

/// The tiny grey line a row ends with.
private struct FinePrint: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption2).foregroundStyle(.tertiary)
    }
}

/// "3 hours ago", set small.
private struct AgoStamp: View {
    var date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named)).modifier(FinePrint())
    }
}

private extension View {
    /// Takes the whole row, with its content at the leading edge.
    func fillLeading() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line that stands in for an empty list.
private struct EmptyNote: View {
    var words: String

    init(_ words: String) { self.words = words }

    var body: some View {
        Text(words).foregroundStyle(.secondary)
    }
}

/// A round icon button without a frame, as the inspector's title bar and headers use.
private struct IconTap: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

// MARK: Title

/// The card's title across the top. A double-click or the pencil turns it into a text box.
struct InspectorTitleBar: View {
    var title: String?
    var canRename: Bool
    var rename: (String) -> Void
    var close: () -> Void

    @State private var draft: String?

    private var trimmedDraft: String { (draft ?? "").trimmingCharacters(in: .whitespaces) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if draft != nil {
                editor
            } else {
                shown
            }
        }
        .padding(12)
    }

    private var shown: some View {
        Group {
            Text(title ?? "Task")
                .lineLimit(3)
                .fillLeading()
                .font(.headline)
                .textSelection(.enabled)
                .onTapGesture(count: 2, perform: startEditing)
            IconTap(symbol: "pencil", help: "Rename", action: startEditing).disabled(!canRename)
            IconTap(symbol: "xmark.circle.fill", help: "Close the inspector", action: close)
                .accessibilityLabel("Close")
        }
    }

    private var editor: some View {
        Group {
            TextField("Title", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .onSubmit(commit)
            Button("Save", action: commit).disabled(trimmedDraft.isEmpty)
            Button("Cancel") { draft = nil }
        }
    }

    private func startEditing() {
        guard canRename else { return }
        draft = title ?? ""
    }

    private func commit() {
        guard !trimmedDraft.isEmpty else { return }
        rename(trimmedDraft)
        draft = nil
    }
}

// MARK: Facts

/// A picker that reports only real changes.
private struct ChangePicker<Value: Hashable, Options: View>: View {
    var title: String
    var current: Value
    var change: (Value) -> Void
    @ViewBuilder var options: () -> Options

    init(_ title: String, current: Value, change: @escaping (Value) -> Void, @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.current = current
        self.change = change
        self.options = options
    }

    var body: some View {
        Picker(title, selection: Binding(get: { current }, set: { if $0 != current { change($0) } })) {
            options()
        }
    }
}

/// Status, bot and priority, changeable in place, and the facts that cannot change.
struct TaskFactsSection: View {
    var task: KanbanTask
    var bots: [String]
    var setStatus: (KanbanStatus) -> Void
    var setBot: (String?) -> Void
    var setPriority: (Int) -> Void

    var body: some View {
        Section {
            ChangePicker("Status", current: task.column ?? .triage, change: setStatus) {
                ForEach(KanbanStatus.allCases, id: \.self) { status in
                    Label(status.title, systemImage: status.symbol)
                        .tag(status)
                        .selectionDisabled(!status.isMoveTarget && status != task.column)
                }
            }
            ChangePicker("Bot", current: task.assignee ?? "", change: { setBot($0.isEmpty ? nil : $0) }) {
                Text("Unassigned").tag("")
                ForEach(bots, id: \.self) { name in
                    HStack(spacing: 6) {
                        BotAvatar(profile: name, size: 14, animated: false)
                        Text(name)
                    }
                    .tag(name)
                }
            }
            ChangePicker("Priority", current: task.priority ?? 0, change: setPriority) {
                ForEach(0..<4, id: \.self) { level in
                    Text(KanbanView.priorityName(level)).tag(level)
                }
            }
            if let made = task.created {
                LabeledContent("Made") { Text(made, format: .relative(presentation: .named)) }
            }
            if let tenant = task.tenant, !tenant.isEmpty {
                LabeledContent("Tenant", value: tenant)
            }
            LabeledContent("Id") { Text(task.id).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }
}

/// Discuss and Stop, when either applies.
struct TaskActionsSection: View {
    var task: KanbanTask
    var discuss: () -> Void
    var stop: () -> Void

    private var hasChat: Bool { !(task.sessionId ?? "").isEmpty }

    var body: some View {
        if task.isWorking || hasChat {
            Section {
                HStack {
                    if hasChat {
                        Button(action: discuss) { Label("Discuss task", systemImage: "bubble.left.and.bubble.right") }
                            .accessibilityIdentifier("task.openChat")
                    }
                    if task.isWorking {
                        Button(role: .destructive, action: stop) { Label("Stop the Worker…", systemImage: "stop.circle") }
                    }
                }
            }
        }
    }
}

struct TaskWarningsSection: View {
    var lines: [String]

    var body: some View {
        if !lines.isEmpty {
            Section("Needs a look") {
                ForEach(lines.indices, id: \.self) { slot in
                    Label(lines[slot], systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: Description and outcome

/// The card's text, with a pencil to rewrite it.
struct TaskDescriptionSection: View {
    var text: String?
    var save: (String) -> Void

    @State private var draft: String?

    var body: some View {
        Section {
            if draft != nil {
                TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 })).font(.body).frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Cancel") { draft = nil }
                    Button("Save") {
                        save(draft ?? "")
                        draft = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if let text, !text.isEmpty {
                MarkdownView(text: text)
            } else {
                EmptyNote("No description yet.")
            }
        } header: {
            HStack {
                Text("Task")
                Spacer()
                if draft == nil {
                    IconTap(symbol: "pencil", help: "Edit the description") { draft = text ?? "" }
                }
            }
        }
    }
}

/// The result (or the latest summary), then what the child tasks came to.
struct TaskOutcomeSection: View {
    var result: String?
    var latestSummary: String?
    var children: [KanbanChildResult]

    var body: some View {
        if let outcome = result ?? latestSummary, !outcome.isEmpty {
            Section(result != nil ? "Result" : "Latest summary") {
                Text(outcome).textSelection(.enabled)
            }
        }
        if !children.isEmpty {
            Section("Children") {
                ForEach(children) { child in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(child.title, systemImage: KanbanStatus(rawValue: child.status)?.symbol ?? "circle")
                        if let outcome = child.result ?? child.latestSummary {
                            Text(outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Runs

private struct RunRow: View {
    var run: KanbanRun

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let who = run.profile {
                        BotAvatar(profile: who, size: 16, animated: false)
                        Text(who).font(.subheadline)
                    }
                    stateTag
                }
                Text("\(run.started, format: .relative(presentation: .named)) · \(KanbanTaskSheet.duration(run.durationSeconds))")
                    .modifier(FinePrint())
                note(run.error, color: .red, lines: 3)
                note(run.summary, color: .secondary, lines: 4)
            }
            Spacer()
            if run.isOpen { ProgressView().controlSize(.small) }
        }
    }

    private var stateTag: some View {
        let colour: Color = run.isOpen ? .accentColor : .secondary
        return Text(run.stateText).foregroundStyle(colour).font(.caption)
    }

    @ViewBuilder private func note(_ words: String?, color: Color, lines: Int) -> some View {
        if let words, !words.isEmpty {
            Text(words).font(.caption).foregroundStyle(color).lineLimit(lines)
        }
    }
}

/// Who took the card and how it went, newest first, and the worker's log.
struct TaskRunsSection: View {
    var taskID: String
    var runs: [KanbanRun]
    var working: Bool

    @State private var logShown = false

    var body: some View {
        Section("Runs") {
            if runs.isEmpty { EmptyNote("No worker has taken it yet.") }
            ForEach(runs.reversed()) { run in RunRow(run: run) }
            DisclosureGroup("Worker log", isExpanded: $logShown) {
                if logShown { KanbanLogView(taskID: taskID, live: working).frame(minHeight: 160, maxHeight: 320) }
            }
        }
    }
}

// MARK: Comments and history

/// The comments so far, and a box to add one.
struct TaskCommentsSection: View {
    var comments: [KanbanComment]
    var working: Bool
    var post: (String) async -> Bool

    @State private var draft = ""
    @State private var sending = false

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section("Comments") {
            if comments.isEmpty { EmptyNote("No comments yet.") }
            ForEach(comments) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.author).font(.caption.weight(.semibold))
                        Spacer()
                        AgoStamp(date: entry.created)
                    }
                    Text(entry.body).font(.subheadline).textSelection(.enabled)
                }
            }
            composer
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextField(working ? "Message the running worker" : "Add a comment", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .font(.title2)
            .foregroundStyle(.tint)
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty || sending)
            .accessibilityLabel("Send the comment")
        }
    }

    private func send() {
        let words = trimmed
        guard !words.isEmpty else { return }
        sending = true
        Task {
            if await post(words) { draft = "" }
            sending = false
        }
    }
}

/// The last sixteen things that happened to the card, newest first.
struct TaskHistorySection: View {
    var events: [KanbanEvent]

    var body: some View {
        if !events.isEmpty {
            Section("History") {
                ForEach(events.suffix(16).reversed()) { event in
                    HStack {
                        Text(event.line).font(.caption)
                        Spacer()
                        AgoStamp(date: event.created)
                    }
                }
            }
        }
    }
}
