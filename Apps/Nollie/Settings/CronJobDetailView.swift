import SwiftUI
import NollieCore

/// One scheduled task: a plain summary with actions, and an editor. Technical fields (the raw
/// cron line, delivery, the JSON record) only show in Developer Mode.
struct CronJobDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nollie.developerMode") private var developerMode = false

    @State private var runtime: GatewayRuntime
    var job: CronJob
    var raw: JSONValue
    var onChange: () -> Void

    @State private var isEditing = false
    /// The complete record from the gateway. The list can carry only a shortened prompt.
    @State private var confirmed: JSONValue?
    @State private var isChanging = false
    @State private var feedback: String?
    @State private var feedbackIsProblem = false
    @State private var askToDelete = false
    @State private var draftName = ""
    @State private var draftSchedule = ""
    @State private var draftPrompt = ""
    @State private var draftDeliver = ""
    @State private var draftJSON = ""
    @State private var jsonProblem: String?
    @State private var hasLoaded = false
    @State private var jsonOpen = false
    @State private var isOnScreen = false
    @State private var picker = ScheduleDraft()
    /// When the Mac slept around a late run, from Nollie's add-on.
    @State private var sleepGaps: [ConversationPost.SleepGap] = []

    init(runtime: GatewayRuntime, job: CronJob, raw: JSONValue, onChange: @escaping () -> Void) {
        _runtime = State(initialValue: runtime)
        self.job = job
        self.raw = raw
        self.onChange = onChange
    }

    // MARK: Derived values

    private var owner: String? { ScheduledWork.owner(raw) }
    private var record: JSONValue { confirmed ?? raw }
    private var current: CronJob { confirmed.flatMap(ScheduledWork.decode) ?? job }

    /// Whether changes may be made now: the page is showing, the job has an owner, the app is
    /// unlocked, and the same gateway is still in use.
    private var allowed: Bool {
        guard isOnScreen, owner?.isEmpty == false else { return false }
        return ScheduledWork.allows(expected: runtime, current: model.runtime, locked: model.lock.isLocked, cancelled: Task.isCancelled)
    }

    private struct Fields: Equatable {
        var name = ""
        var schedule = ""
        var prompt = ""
        var deliver = ""
    }

    /// The fields as the gateway has them now.
    private var stored: Fields {
        Fields(
            name: current.name ?? "",
            schedule: current.schedule ?? "",
            prompt: current.prompt ?? current.promptPreview ?? "",
            deliver: current.deliver ?? "")
    }

    private var drafted: Fields {
        Fields(name: draftName, schedule: draftSchedule, prompt: draftPrompt, deliver: draftDeliver)
    }

    private var jsonChanged: Bool { draftJSON != Self.pretty(record) }
    private var hasChanges: Bool { drafted != stored || (developerMode && jsonChanged) }

    private var canSave: Bool {
        let named = !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let described = !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasChanges && named && described && !isChanging && allowed
    }

    private var deliveryChoices: [String] {
        let known = ["bot-chat", "local", "telegram", "discord", "slack", "email", draftDeliver]
        return Set(known.filter { !$0.isEmpty }).sorted()
    }

    private var scheduleSummary: String {
        let line = current.schedule ?? ""
        let words = CronSchedule.describe(line)
        return (developerMode || words != line) ? words : "Custom schedule"
    }

    private var lastCheckSummary: String {
        if current.lastRunAt == nil && current.lastStatus == nil { return "Not checked yet" }
        let when = ScheduledWork.date(current.lastRunAt) ?? "Time not reported"
        return "\(when) \u{00B7} \(ScheduledWork.result(current))"
    }

    private var title: String {
        guard let name = current.name, !name.isEmpty else { return "Scheduled task" }
        return name
    }

    // MARK: Body

    var body: some View {
        SettingsList {
            if isEditing {
                editor
                feedbackLine
            } else {
                summary
                actions
                Section {
                    Button("Edit details", systemImage: "pencil") {
                        loadDrafts()
                        isEditing = true
                    }
                    .disabled(isChanging || confirmed == nil)
                    .testID("schedules.edit")
                }
            }
            Section {
                Button("Delete task", systemImage: "trash", role: .destructive) { askToDelete = true }
                    .disabled(run.isBusy || isChanging)
                .testID("schedules.delete")
            }
        }
        .disabled(isChanging || !allowed)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editBar }
        .confirmationDialog(
            "Delete this scheduled task?", isPresented: $askToDelete, titleVisibility: .visible,
            actions: { Button("Delete task", role: .destructive, action: asTask(deleteTask)) },
            message: { Text("Future checks will stop. Previous results stay in the chat.") })
        .task { await firstLoad() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: model.runtime.map(ObjectIdentifier.init)) { _, _ in
            if model.runtime !== runtime { dismiss() }
        }
        .onChange(of: model.lock.isLocked) { _, locked in
            if locked { dismiss() }
        }
        // The list refreshed beneath this page (after Run now, the last run and result move on). The
        // JSON editor follows along unless it was edited; otherwise Save would light up for no reason
        // and push stale run fields back.
        .onChange(of: raw) { _, fresh in
            guard allowed, ScheduledWork.confirms(fresh, jobID: job.identity, profile: owner) else { return }
            let wasFollowing = !jsonChanged
            // A list refresh can hold only the prompt preview, so keep the full prompt fetched earlier.
            let merged = (record.objectValue ?? [:]).merging(fresh.objectValue ?? [:]) { _, latest in latest }
            confirmed = .object(merged)
            if wasFollowing { draftJSON = Self.pretty(record) }
        }
    }

    @ToolbarContentBuilder private var editBar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    loadDrafts()
                    isEditing = false
                }
                .disabled(isChanging)
                .testID("schedules.edit.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: asTask(save))
                    .disabled(!canSave)
                    .testID("schedules.edit.save")
            }
        }
    }

    @ViewBuilder private var feedbackLine: some View {
        if let feedback {
            Text(feedback).font(.footnote).foregroundStyle(feedbackIsProblem ? Color.red : Color.secondary)
        }
    }

    // MARK: Reading mode

    private var summary: some View {
        Section {
            if let task = current.prompt ?? current.promptPreview, !task.isEmpty {
                Text(task).lineLimit(3).testID("schedules.taskSummary")
            }
            LabeledContent("Status", value: ScheduledWork.status(current, raw: record))
                .testID("schedules.status")
            LabeledContent("When", value: scheduleSummary)
            LabeledContent("Next check", value: ScheduledWork.next(current))
            LabeledContent("Last check", value: lastCheckSummary)
            if let late = ScheduledWork.lateRun(record),
               let line = SleepNote.scheduleLine(due: late.due, ran: late.ran, gaps: sleepGaps) {
                Text(line).small(.footnote, .secondary)
                    .testID("schedules.lateRun")
                    .task(id: late.due) { await loadSleep(around: late.due) }
            }
            if let owner, owner != "default" {
                LabeledContent("Assistant", value: runtime.profiles.first(where: { $0.name == owner })?.shownName ?? owner)
            }
        }
    }

    private var actions: some View {
        Section {
            if !ScheduledWork.completed(current) {
                let isPaused = ScheduledWork.paused(current)
                Button(isPaused ? "Resume checks" : "Pause checks", systemImage: isPaused ? "play.circle" : "pause.circle") {
                    Task { await setPaused(!isPaused) }
                }
                .disabled(isChanging)
                .testID("schedules.pauseResume")
            }
            runButton
            if isChanging { ProgressView("Saving…") }
            if let feedback {
                Text(feedback)
                    .font(.footnote)
                    .foregroundStyle(feedbackIsProblem ? Color.red : Color.secondary)
                    .testID("schedules.feedback")
            }
        } footer: {
            run.note.map { note in
                Text(note.text).foregroundStyle(note.isProblem ? Color.red : Color.secondary)
            }
        }
    }

    private var runButton: some View {
        let blocked = isChanging || run.isBusy || CronRun.isRunning(record)
            || ScheduledWork.paused(current) || ScheduledWork.completed(current)
        let icon: AnyView = run.symbol.map { AnyView(Image(systemName: $0)) } ?? AnyView(ProgressView().controlSize(.small))
        return Button(action: asTask(runNow)) {
            Label(title: { Text(run.title).contentTransition(.opacity) }, icon: { icon })
        }
        .disabled(blocked)
        .testID("cron.runNow")
    }

    // MARK: Editing mode

    private var editor: some View {
        Group {
            Section("Task") {
                TextField("Name", text: $draftName).testID("schedules.edit.name")
                TextEditor(text: $draftPrompt)
                    .frame(minHeight: 100)
                    .font(.body)
                    .testID("schedules.edit.prompt")
            }
            scheduleSection
            if developerMode {
                Section("Delivery") {
                    Picker("Delivers to", selection: $draftDeliver) {
                        ForEach(deliveryChoices, id: \.self) { choice in Text(choice).tag(choice) }
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $jsonOpen) {
                        TextEditor(text: $draftJSON)
                            .frame(minHeight: 220)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                        if let jsonProblem {
                            Text(jsonProblem).small(.caption, .red)
                        }
                    } label: {
                        Label("Raw JSON", systemImage: "curlybraces")
                    }
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section("When") {
            Picker("Repeats", selection: $picker.repeats) {
                Text("Once").tag(ScheduleDraft.Repeat.once)
                Text("Every day").tag(ScheduleDraft.Repeat.daily)
                Text("Weekdays").tag(ScheduleDraft.Repeat.weekdays)
                Text("Weekends").tag(ScheduleDraft.Repeat.weekends)
                Text("Weekly").tag(ScheduleDraft.Repeat.weekly)
                if developerMode || picker.repeats == .monthly {
                    Text("Monthly").tag(ScheduleDraft.Repeat.monthly)
                }
                if developerMode || picker.repeats == .custom {
                    Text(developerMode ? "Custom cron" : "Custom schedule").tag(ScheduleDraft.Repeat.custom)
                }
            }
            .testID("schedules.edit.repeat")

            if picker.repeats == .weekly {
                Picker("Day", selection: $picker.weekday) {
                    ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .testID("schedules.edit.day")
            }
            if picker.repeats == .monthly {
                Picker("Day of month", selection: $picker.monthDay) {
                    ForEach(Array(1...31), id: \.self) { day in Text(String(day)).tag(day) }
                }
            }
            timeControl
            if developerMode && picker.repeats != .once {
                LabeledContent("Cron") {
                    Text(draftSchedule).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: picker) { _, _ in applyPicker() }
    }

    @ViewBuilder private var timeControl: some View {
        switch picker.repeats {
        case .once:
            DatePicker("Date and time", selection: $picker.onceAt, displayedComponents: [.date, .hourAndMinute])
        case .custom where developerMode:
            TextField("min hour day month weekday", text: $draftSchedule)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
        case .custom:
            Text("This task has a custom schedule. Leave it as it is, or choose a repeat above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            DatePicker("Time", selection: $picker.time, displayedComponents: .hourAndMinute)
        }
    }

    // MARK: Drafts

    /// Puts the gateway's values back into the editing fields and the pickers.
    private func loadDrafts(from json: JSONValue? = nil) {
        let now = stored
        draftName = now.name
        draftSchedule = now.schedule
        draftPrompt = now.prompt
        draftDeliver = now.deliver
        draftJSON = Self.pretty(json ?? record)
        jsonProblem = nil
        picker.read(draftSchedule)
    }

    private func applyPicker() {
        if let line = picker.line(keeping: draftSchedule), line != draftSchedule {
            draftSchedule = line
        }
    }

    private static func pretty(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let text = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return value.displayText }
        return String(decoding: text, as: UTF8.self)
    }

    // MARK: Talking to the gateway

    private func failed(_ error: Error) {
        guard allowed else { return }
        feedback = ScheduledWork.failureMessage(error)
        feedbackIsProblem = true
    }

    /// Why the last run was late, when the add-on knows. Without it the line says only that it ran late.
    private func loadSleep(around due: Date) async {
        guard allowed else { return }
        let gaps = try? await HermesSleepGaps(api: runtime.api).gaps(since: due.addingTimeInterval(-3600))
        guard allowed, let gaps else { return }
        sleepGaps = gaps
    }

    private func firstLoad() async {
        guard !hasLoaded, !Task.isCancelled else { return }
        isOnScreen = true
        guard allowed else { return }
        hasLoaded = true
        loadDrafts(from: raw)

        isChanging = true
        defer { isChanging = false }
        do {
            let full: JSONValue = try await runtime.api.get("/api/cron/jobs/\(job.identity)", profile: owner)
            guard allowed else { return }
            guard ScheduledWork.confirms(full, jobID: job.identity, profile: owner) else { throw ScheduleConfirmationError() }
            confirmed = full
            loadDrafts()
        } catch {
            guard allowed else { return }
            feedback = "Couldn't refresh this task. Reopen Schedules before making changes."
            feedbackIsProblem = true
        }
    }

    private func save() async {
        guard allowed, isEditing, confirmed != nil, !isChanging else { return }
        var changes: [String: JSONValue] = [:]

        // Whatever the raw editor changed takes priority; the form's fields are layered over it.
        if developerMode && jsonChanged {
            guard let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(draftJSON.utf8)))?.objectValue
            else {
                jsonProblem = "The JSON does not parse."
                return
            }
            jsonProblem = nil
            for (key, value) in object where record[key] != value { changes[key] = value }
        }
        let before = stored
        if draftName != before.name { changes["name"] = .string(draftName) }
        if draftSchedule != before.schedule { changes["schedule"] = .string(draftSchedule) }
        if draftPrompt != before.prompt { changes["prompt"] = .string(draftPrompt) }
        if developerMode, draftDeliver != before.deliver, !draftDeliver.isEmpty {
            changes["deliver"] = .string(draftDeliver)
        }

        isChanging = true
        feedback = nil
        defer { isChanging = false }
        do {
            if !changes.isEmpty {
                let reply: JSONValue = try await runtime.api.send(
                    "PUT", "/api/cron/jobs/\(job.identity)", profile: owner,
                    json: .object(["updates": .object(changes)]))
                guard allowed else { return }
                guard ScheduledWork.confirms(reply, jobID: job.identity, profile: owner) else { throw ScheduleConfirmationError() }
                confirmed = reply
                loadDrafts(from: reply)
            }
            feedback = "Saved."
            feedbackIsProblem = false
            isEditing = false
            onChange()
        } catch {
            failed(error)
        }
    }

    private func setPaused(_ pause: Bool) async {
        guard allowed, !isChanging else { return }
        isChanging = true
        feedback = nil
        defer { isChanging = false }
        do {
            let path = "/api/cron/jobs/\(job.identity)/\(pause ? "pause" : "resume")"
            let reply: JSONValue = try await runtime.api.send("POST", path, profile: owner, body: EmptyBody())
            guard allowed else { return }
            guard ScheduledWork.confirms(reply, jobID: job.identity, enabled: !pause, profile: owner) else {
                throw ScheduleConfirmationError()
            }
            take(reply)
            feedback = pause ? "Paused. No future checks will start." : "Resumed. Your next check is scheduled."
            feedbackIsProblem = false
            onChange()
        } catch {
            failed(error)
        }
    }

    /// Adopts a fresh record from the gateway; the JSON editor follows it unless it was edited.
    private func take(_ reply: JSONValue) {
        let wasFollowing = !jsonChanged
        confirmed = reply
        if wasFollowing { draftJSON = Self.pretty(reply) }
    }

    private func deleteTask() async {
        guard allowed, !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            let _: JSONValue = try await runtime.api.send("DELETE", "/api/cron/jobs/\(job.identity)", profile: owner, body: EmptyBody())
            guard allowed else { return }
            onChange()
            dismiss()
        } catch {
            failed(error)
        }
    }

    // MARK: Run now

    /// Progress of Run now for this task. Held app-wide, not by the page, so leaving does not lose it (`CronRuns`).
    private var runKey: String {
        [runtime.connection.id.uuidString, owner ?? "", job.identity].joined(separator: "|")
    }

    private var run: CronRun { CronRuns.shared.run(runKey) }

    /// Run now. Shows "Running…" immediately and sends a single request no matter how often it is
    /// tapped. Afterwards "Started" or "Finished" appears briefly, or else a plain-language error.
    private func runNow() async {
        guard allowed, !isChanging, !ScheduledWork.paused(current), !ScheduledWork.completed(current),
              !CronRun.isRunning(record)
        else { return }

        let key = runKey
        var accepted = false
        CronRuns.shared.update(key) { accepted = $0.begin() }
        guard accepted else { return }

        let attempt = CronRuns.shared.run(key).attempt
        let lastRun = current.lastRunAt
        let jobID = job.identity
        defer {
            Task {
                try? await Task.sleep(for: .seconds(CronRun.confirmationSeconds))
                CronRuns.shared.update(key) { $0.settle(attempt: attempt) }
            }
        }
        func giveUp() {
            CronRuns.shared.update(key) { $0.answered(nil, lastRunBefore: lastRun, jobID: jobID) }
        }

        do {
            let reply: JSONValue = try await runtime.api.send("POST", "/api/cron/jobs/\(jobID)/trigger", profile: owner, body: EmptyBody())
            guard allowed else { return giveUp() }
            let genuine = ScheduledWork.confirms(reply, jobID: jobID, profile: owner)
            CronRuns.shared.update(key) { $0.answered(genuine ? reply : nil, lastRunBefore: lastRun, jobID: jobID) }
            if genuine { take(reply) }
        } catch {
            // Silence may just mean the task ran longer than we waited, so check with the gateway
            // whether it is still going.
            guard allowed else { return giveUp() }
            var latest: JSONValue?
            if CronRun.mayStillBeRunning(after: error) {
                latest = try? await runtime.api.get("/api/cron/jobs/\(jobID)", profile: owner)
            }
            guard allowed else { return giveUp() }
            if let seen = latest, !ScheduledWork.confirms(seen, jobID: jobID, profile: owner) { latest = nil }
            CronRuns.shared.update(key) { $0.failed(error, jobNow: latest, lastRunBefore: lastRun, jobID: jobID) }
            if let latest { take(latest) }
        }
        if CronRuns.shared.run(key).isBusy { onChange() }
    }
}

private struct ScheduleConfirmationError: LocalizedError {
    var errorDescription: String? { "Your assistant did not confirm the change. Refresh before trying again." }
}
