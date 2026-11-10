import Foundation

/// A small, short-lived view of background workers: who is busy, and on which card since when. It
/// carries a card's title and nothing else of the task, and no chat history.
public struct KanbanActivity: Equatable, Sendable {
    public enum State: Sendable { case working, idle, unknown }

    /// The card a bot is working on: the longest-running one when it has several.
    public struct Work: Equatable, Sendable {
        public var taskID: String
        public var title: String
        public var since: Date?
        public init(taskID: String, title: String, since: Date? = nil) { self.taskID = taskID; self.title = title; self.since = since }
    }

    public var activeProfiles: Set<String>
    public var checkedAt: Date
    public var complete: Bool
    public var work: [String: Work]

    public init(activeProfiles: Set<String> = [], checkedAt: Date = .distantPast, complete: Bool = false, work: [String: Work] = [:]) {
        self.activeProfiles = activeProfiles; self.checkedAt = checkedAt; self.complete = complete; self.work = work
    }

    /// The card the bot is on now, while the last look is fresh.
    public func work(for profile: String, now: Date = Date()) -> Work? {
        state(for: profile, now: now) == .working ? work[profile] : nil
    }

    public func state(for profile: String, now: Date = Date()) -> State {
        let age = now.timeIntervalSince(checkedAt)
        guard age >= -5, age < 45 else { return .unknown }
        if activeProfiles.contains(profile) { return .working }
        return complete ? .idle : .unknown
    }

    /// `profile` can name the dispatcher. The task's explicit assignee owns its work.
    public static func owner(of worker: KanbanWorker) -> String? {
        let assignee = worker.taskAssignee?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = worker.profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        return assignee?.isEmpty == false ? assignee : (profile?.isEmpty == false ? profile : nil)
    }

    /// `connection` is the gateway the boards are on, whose Private list counts.
    public static func read(boards: [String], profiles: Set<String>, connection: UUID? = nil, now: Date = Date(),
                            load: @escaping @Sendable (String) async throws -> [KanbanWorker]) async -> Self {
        let slugs = Set(boards).filter { !$0.isEmpty && !PrivateBots.isPrivate($0, connection: connection) }
        guard !slugs.isEmpty else { return Self() }
        return await withTaskGroup(of: ([String: Work], Bool).self) { group in
            for slug in slugs {
                group.addTask {
                    do {
                        let workers = try await load(slug)
                        try Task.checkCancellation()
                        var found: [String: Work] = [:]
                        for worker in workers {
                            guard worker.taskStatus == "running", (worker.workerPid ?? 0) > 0,
                                  !worker.taskId.isEmpty, let owner = owner(of: worker),
                                  !PrivateBots.isPrivate(owner, connection: connection), profiles.contains(owner) else { continue }
                            found[owner] = earlier(found[owner], Self.work(of: worker))
                        }
                        return (found, true)
                    } catch { return ([:], false) }
                }
            }
            var busy: [String: Work] = [:], complete = true
            for await (found, succeeded) in group {
                busy.merge(found) { earlier($0, $1) }
                complete = complete && succeeded
            }
            guard !Task.isCancelled else { return Self() }
            return Self(activeProfiles: Set(busy.keys), checkedAt: now, complete: complete, work: busy)
        }
    }

    static func work(of worker: KanbanWorker) -> Work {
        let title = worker.taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Work(taskID: worker.taskId, title: title.isEmpty ? String(localized: "A Board task", table: "Core") : title,
                    since: worker.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    /// Of two cards, the one begun first (an undated one last).
    static func earlier(_ a: Work?, _ b: Work) -> Work {
        guard let a else { return b }
        return (a.since ?? .distantFuture) <= (b.since ?? .distantFuture) ? a : b
    }
}
