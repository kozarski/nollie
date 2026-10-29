import SwiftUI
import NollieCore

/// Creates a task: title, what to do, which bot, how urgent, and whether it begins in triage.
struct KanbanNewTaskSheet: View {
    /// Runs after the task is created, passing the dispatcher's warning if nothing would pick it up.
    var onMade: (String?) -> Void

    /// What has been filled in so far.
    private struct Draft {
        var title = ""
        var details = ""
        var assignee = ""
        var priority = 0
        var startInTriage = false

        var cleanTitle: String { title.trimmingCharacters(in: .whitespaces) }

        var request: KanbanNewTask {
            KanbanNewTask(
                title: cleanTitle,
                body: details.isEmpty ? nil : details,
                assignee: assignee.isEmpty ? nil : assignee,
                priority: priority,
                triage: startInTriage)
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Draft()
    @State private var isSaving = false
    @State private var problem: String?

    private var store: KanbanStore? { model.runtime?.kanban }

    /// Bots the task can go to: the board's assignees first, then any other profile.
    private var botNames: [String] {
        let onBoard = store?.assignees.map(\.name) ?? []
        let others = (model.runtime?.profiles ?? []).map(\.name).filter { !onBoard.contains($0) }
        return onBoard + others
    }

    private var footnote: String {
        draft.startInTriage
            ? String(localized: "It stays in Triage until someone picks it up.")
            : String(localized: "With a bot chosen, the task starts in Ready and the dispatcher passes it along.")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("What to do", text: $draft.details, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section(footer: Text(footnote)) {
                    Picker("Bot", selection: $draft.assignee) {
                        Text("Unassigned").tag("")
                        ForEach(botNames, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(0..<4) { Text(KanbanView.priorityName($0)).tag($0) }
                    }
                    Toggle("Start in triage", isOn: $draft.startInTriage)
                }
                if let problem {
                    Section { Text(problem).small(.footnote, .red) }
                }
            }
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { bar }
            .task { await prepare() }
        }
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: { dismiss() })
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Create") { Task { await create() } }
                .disabled(isSaving || draft.cleanTitle.isEmpty)
        }
    }

    /// Loads the board's assignees and starts with the bot in front, when it can take the task.
    private func prepare() async {
        await store?.loadAssignees()
        if draft.assignee.isEmpty, let current = model.runtime?.selectedProfile, botNames.contains(current) {
            draft.assignee = current
        }
    }

    private func create() async {
        guard let store else { return }
        isSaving = true
        defer { isSaving = false }
        guard let made = await store.create(draft.request) else {
            problem = store.lastError ?? String(localized: "The gateway turned the task away.")
            return
        }
        dismiss()
        onMade(made.warning)
    }
}
