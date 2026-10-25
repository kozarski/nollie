import SwiftUI
import NollieCore

/// The Schedules page: the things the gateway's scheduler is set to do, each opening its own page.
struct CronView: View {
    private struct NewTask: Identifiable {
        let id = UUID()
        let runtime: GatewayRuntime
    }

    @Environment(AppModel.self) private var model
    @AppStorage("nollie.developerMode") private var developerMode = false
    @State private var jobs: [CronJob] = []
    @State private var records: [String: JSONValue] = [:]
    @State private var problem: String?
    @State private var listedFrom: GatewayRuntime?
    @State private var newTask: NewTask?
    @State private var openingChat = false
    @State private var chatTask: Task<Void, Never>?

    private var runtime: GatewayRuntime? { model.runtime }

    /// Whether work started for `expected` may still change the screen.
    private func stillValid(for expected: GatewayRuntime) -> Bool {
        ScheduledWork.allows(expected: expected, current: model.runtime, locked: model.lock.isLocked, cancelled: Task.isCancelled)
    }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Things Nollie is watching")
            if let problem {
                Text(problem).small(.footnote, .red)
            }
            if jobs.isEmpty, problem == nil {
                Placeholder("Nothing scheduled yet", symbol: "clock", detail: "Ask Nollie for a reminder or something to keep an eye on.")
            }
            ForEach(jobs, id: \.identity) { job in row(for: job) }
        }
        .navigationTitle("Schedules")
        .testID("schedules.list")
        .toolbar { ToolbarItem(placement: .primaryAction) { addButton } }
        .sheet(item: $newTask, onDismiss: { Task { await load() } }) { context in
            NewScheduledTaskSheet(runtime: context.runtime, onCreate: { await load() })
                .sheetFrame(.form)
                .withAppModel()
        }
        .contentMargins(.top, 14, for: .scrollContent)
        .reloadable { await load() }
        .task(id: runtime.map(ObjectIdentifier.init)) { await load() }
        .onDisappear {
            chatTask?.cancel()
            chatTask = nil
        }
    }

    private func row(for job: CronJob) -> some View {
        let record = records[job.identity] ?? .null
        let title = job.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Scheduled task"
        return NavigationLink {
            if let listedFrom {
                CronJobDetailView(runtime: listedFrom, job: job, raw: record, onChange: { Task { await load() } })
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ScheduledWork.paused(job) ? "pause.circle" : "clock")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium))
                    Text(ScheduledWork.status(job, raw: record)).font(.caption.weight(.semibold))
                    Text("Next check: \(ScheduledWork.next(job))").small(.caption, .secondary)
                    if job.lastRunAt != nil || job.lastStatus != nil {
                        let when = ScheduledWork.date(job.lastRunAt) ?? "Time not reported"
                        Text("Last check: \(when) \u{00B7} \(ScheduledWork.result(job))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(model.lock.isLocked || listedFrom !== runtime)
        .testID("schedules.task.\(job.identity)")
    }

    /// In developer mode this makes a task by hand. Otherwise it opens Nollie's own chat to ask.
    private var addButton: some View {
        Button {
            guard !model.lock.isLocked, !openingChat, let runtime else { return }
            if developerMode {
                newTask = NewTask(runtime: runtime)
            } else {
                chatTask = Task { await askNollie(on: runtime) }
            }
        } label: {
            if openingChat {
                ProgressView("Opening Nollie…")
            } else if developerMode {
                Label("New scheduled task", systemImage: "plus")
            } else {
                Label("Ask Nollie", systemImage: "bubble.left")
            }
        }
        .disabled(openingChat || model.lock.isLocked || runtime?.profiles.isEmpty != false)
        .testID("schedules.new")
    }

    private func askNollie(on runtime: GatewayRuntime) async {
        guard stillValid(for: runtime) else { return }
        openingChat = true
        problem = nil
        defer { openingChat = false }

        let failure = await model.openMainChat("default")
        guard stillValid(for: runtime) else { return }
        if let failure {
            problem = failure
        } else {
            model.botSheet = nil
        }
    }

    private func load() async {
        guard let runtime, !model.lock.isLocked, !Task.isCancelled else { return }
        if listedFrom !== runtime {
            jobs = []
            records = [:]
            problem = nil
        }
        listedFrom = runtime

        do {
            // No bot filter: with none given, the dashboard lists every bot's jobs.
            let reply: JSONValue = try await runtime.api.get("/api/cron/jobs")
            guard stillValid(for: runtime) else { return }
            let entries = reply["jobs"]?.arrayValue ?? reply["items"]?.arrayValue ?? reply.arrayValue ?? []
            let decoded = entries.compactMap { entry in ScheduledWork.decode(entry).map { ($0, entry) } }
            jobs = decoded.map(\.0)
            records = Dictionary(decoded.map { ($0.0.identity, $0.1) }, uniquingKeysWith: { _, later in later })
            problem = nil
        } catch {
            guard stillValid(for: runtime) else { return }
            problem = "Couldn't load Schedules. Check your connection and try again."
        }
    }
}
