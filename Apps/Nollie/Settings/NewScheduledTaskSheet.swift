import SwiftUI
import NollieCore

/// The small set of fields the dashboard accepts when a scheduled task is created.
struct ScheduledTaskDraft {
    enum Starter: String, CaseIterable, Identifiable {
        case price, weekend, morning, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .price: String(localized: "Watch a price", comment: "A starter idea for a scheduled task; also its first name")
            case .weekend: String(localized: "Weekend ideas", comment: "A starter idea for a scheduled task; also its first name")
            case .morning: String(localized: "Morning brief", comment: "A starter idea for a scheduled task; also its first name")
            case .project: String(localized: "Project check-in", comment: "A starter idea for a scheduled task; also its first name")
            }
        }
        var symbol: String {
            switch self {
            case .price: "tag"
            case .weekend: "sun.max"
            case .morning: "cup.and.saucer"
            case .project: "checklist"
            }
        }
        var subjectLabel: String {
            switch self {
            case .price: String(localized: "Item or link")
            case .weekend: String(localized: "Place and interests")
            case .morning: String(localized: "What matters to you")
            case .project: String(localized: "Project or existing task")
            }
        }
        // Goes to the model, so it stays in English.
        var instructions: String {
            switch self {
            case .price: "Check the current price and availability. Include the seller, total price and source link when a worthwhile change happens. Do not buy anything."
            case .weekend: "Find a few relevant weekend ideas with dates, prices and source links. Avoid repeating ideas already shared. Do not book anything."
            case .morning: "Give a short brief of meaningful changes, upcoming commitments and decisions that need attention, using only connected sources you can access."
            case .project: "Review the existing project's tasks and recent progress. Reuse its authoritative task records; do not create a second list. Share completed work, genuine blockers or an important next step."
            }
        }
    }
    enum Repetition: String, CaseIterable, Identifiable {
        case once, daily, weekdays, weekends, weekly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .once: String(localized: "Once", comment: "How often a task repeats")
            case .daily: String(localized: "Every day", comment: "How often a task repeats")
            case .weekdays: String(localized: "Weekdays", comment: "How often a task repeats")
            case .weekends: String(localized: "Weekends", comment: "How often a task repeats")
            case .weekly: String(localized: "Weekly", comment: "How often a task repeats")
            }
        }
    }

    var name = ""
    var prompt = ""
    var profile = ""
    var repetition = Repetition.once
    var weekday = 1
    var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    var onceAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
    var starter: Starter?
    var subject = ""
    var stopRule = ""

    mutating func use(_ choice: Starter) {
        starter = choice
        name = choice.title
        prompt = choice.instructions
        repetition = choice == .weekend ? .weekly : .daily
        weekday = 5
    }

    // Goes to the model, so it stays in English.
    var instructions: String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard starter != nil else { return text }
        return """
        Subject: \(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        \(text)

        Notify only about a meaningful change, useful result, failure that needs attention, or a decision only the user can make. When nothing has changed, return [SILENT]. Compare with the previous check and do not repeat the same update or question. Keep one current follow-up for this topic; do not create duplicate schedules.

        Stop rule: \(stopRule.trimmingCharacters(in: .whitespacesAndNewlines))
        Check this rule before doing more work. When it is met, do not continue the task; ask Nollie in the main chat to pause this schedule if you cannot pause it yourself. Never claim the schedule is paused without confirmation. Keep existing approval requirements and do not make purchases, bookings or send messages without authorization.
        """
    }

    var canCreate: Bool { canCreate(at: .now) }

    func canCreate(at now: Date) -> Bool {
        !profile.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (starter == nil || (!subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !stopRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            && (repetition != .once || onceAt > now)
    }

    func schedule(calendar: Calendar = .current) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        let days: String
        switch repetition {
        case .once: return CronSchedule.onceExpression(onceAt)
        case .daily: days = "*"
        case .weekdays: days = "1-5"
        case .weekends: days = "0,6"
        case .weekly: days = String(min(6, max(0, weekday)))
        }
        return "\(clock.minute ?? 0) \(clock.hour ?? 9) * * \(days)"
    }

    func payload(calendar: Calendar = .current) -> JSONValue {
        .object([
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "prompt": .string(instructions),
            "schedule": .string(schedule(calendar: calendar)),
            "deliver": .string("bot-chat"),
        ])
    }

    func confirmsCreation(_ reply: JSONValue, payload: JSONValue) -> Bool {
        guard let job = ScheduledWork.decode(reply), !job.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ScheduledWork.owner(reply) == profile,
              job.name == payload["name"]?.stringValue,
              job.prompt == payload["prompt"]?.stringValue,
              job.deliver == payload["deliver"]?.stringValue,
              let actual = job.schedule, let expected = payload["schedule"]?.stringValue else { return false }
        if let expectedDate = CronSchedule.onceDate(expected) {
            return CronSchedule.onceDate(actual) == expectedDate
        }
        return actual == expected
    }
}

/// A lost response can still mean the scheduler accepted the task. This sheet never
/// sends a second create request; closing it returns to the list for reconciliation.
struct ScheduledTaskSubmission {
    private(set) var hasSubmitted = false
    mutating func begin() -> Bool {
        guard !hasSubmitted else { return false }
        hasSubmitted = true
        return true
    }
}

struct NewScheduledTaskSheet: View {
    @State private var runtime: GatewayRuntime
    var onCreate: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ScheduledTaskDraft()
    @State private var saving = false
    @State private var error: String?
    @State private var submission = ScheduledTaskSubmission()
    @State private var presented = false

    init(runtime: GatewayRuntime, onCreate: @escaping () async -> Void) {
        _runtime = State(initialValue: runtime)
        self.onCreate = onCreate
    }

    private var allowed: Bool {
        presented && ScheduledWork.allows(expected: runtime, current: model.runtime,
                                          locked: model.lock.isLocked, cancelled: Task.isCancelled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu {
                        ForEach(ScheduledTaskDraft.Starter.allCases) { choice in
                            Button(choice.title, systemImage: choice.symbol) { draft.use(choice) }
                                .accessibilityIdentifier("schedules.starter.\(choice.id)")
                        }
                    } label: {
                        Label(draft.starter?.title ?? String(localized: "Start with an idea"), systemImage: draft.starter?.symbol ?? "sparkles")
                    }
                    .accessibilityIdentifier("schedules.starters")
                }
                Section("Task") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("schedules.create.name")
                    Picker("Bot", selection: $draft.profile) {
                        ForEach(runtime.profiles) { profile in
                            Text(profile.shownName).tag(profile.name)
                                .accessibilityIdentifier("schedules.create.bot.\(profile.name)")
                        }
                    }
                    .accessibilityIdentifier("schedules.create.bot")
                }
                if let starter = draft.starter {
                    Section {
                        TextField(starter.subjectLabel, text: $draft.subject, axis: .vertical)
                            .accessibilityIdentifier("schedules.create.subject")
                        TextField("Stop when", text: $draft.stopRule,
                                  prompt: Text("After 30 days or when I choose one"), axis: .vertical)
                            .accessibilityLabel("Stop when")
                            .accessibilityIdentifier("schedules.create.stopRule")
                    } header: { Text("Focus and stopping rule") }
                }
                Section("What it does") {
                    TextEditor(text: $draft.prompt)
                        .frame(minHeight: 110)
                        .accessibilityLabel("What the task should do")
                        .accessibilityIdentifier("schedules.create.prompt")
                }
                Section {
                    Picker("Repeats", selection: $draft.repetition) {
                        ForEach(ScheduledTaskDraft.Repetition.allCases) { repetition in
                            Text(repetition.title).tag(repetition)
                                .accessibilityIdentifier("schedules.create.repeats.\(repetition.rawValue)")
                        }
                    }
                    .accessibilityIdentifier("schedules.create.repeats")
                    if draft.repetition == .weekly {
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(0..<7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day]).tag(day)
                            }
                        }
                    }
                    if draft.repetition == .once {
                        DatePicker("Date and time", selection: $draft.onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("schedules.create.onceAt")
                    } else {
                        DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("When")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .disabled(saving || !allowed)
            .navigationTitle("New scheduled task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(submission.hasSubmitted ? "Close" : "Cancel") { dismiss() }
                        .disabled(saving)
                        .accessibilityIdentifier("schedules.create.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await create() } }
                        .disabled(saving || submission.hasSubmitted || !allowed || !draft.canCreate || !runtime.profiles.contains { $0.name == draft.profile })
                        .accessibilityIdentifier("schedules.create.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                presented = true
                if draft.profile.isEmpty {
                    draft.profile = runtime.profiles.first { $0.name == runtime.selectedProfile }?.name
                        ?? runtime.profiles.first?.name ?? ""
                }
            }
            .onDisappear { presented = false }
            .onChange(of: model.runtime.map(ObjectIdentifier.init)) { _, _ in if !allowed { dismiss() } }
            .onChange(of: model.lock.isLocked) { _, locked in if locked { dismiss() } }
        }
    }

    private func create() async {
        guard allowed, !saving, draft.canCreate,
              runtime.profiles.contains(where: { $0.name == draft.profile }), submission.begin() else { return }
        let submitted = draft
        let payload = submitted.payload()
        saving = true
        defer { saving = false }
        do {
            let reply: JSONValue = try await runtime.api.send("POST", "/api/cron/jobs", profile: submitted.profile, json: payload)
            guard allowed else { return }
            guard submitted.confirmsCreation(reply, payload: payload) else {
                error = String(localized: "The new task was not confirmed. Close this sheet and check Schedules before creating it again.")
                return
            }
            await onCreate()
            guard allowed else { return }
            dismiss()
        } catch {
            guard allowed else { return }
            self.error = String(localized: "The new task was not confirmed. It may have been saved. Close this sheet and check Schedules before creating it again.")
        }
    }
}
