import Foundation

/// A small, short-lived view of background workers. It carries no task text or chat history.
public struct KanbanActivity: Equatable, Sendable {
    public enum State: Sendable { case working, idle, unknown }
    public var activeProfiles: Set<String>
    public var checkedAt: Date
    public var complete: Bool

    public init(activeProfiles: Set<String> = [], checkedAt: Date = .distantPast, complete: Bool = false) {
        self.activeProfiles = activeProfiles; self.checkedAt = checkedAt; self.complete = complete
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
        return await withTaskGroup(of: (Set<String>, Bool).self) { group in
            for slug in slugs {
                group.addTask {
                    do {
                        let workers = try await load(slug)
                        try Task.checkCancellation()
                        let owners = workers.compactMap { worker -> String? in
                            guard worker.taskStatus == "running", (worker.workerPid ?? 0) > 0,
                                  !worker.taskId.isEmpty, let owner = owner(of: worker),
                                  !PrivateBots.isPrivate(owner, connection: connection), profiles.contains(owner) else { return nil }
                            return owner
                        }
                        return (Set(owners), true)
                    } catch { return ([], false) }
                }
            }
            var active = Set<String>(), complete = true
            for await (owners, succeeded) in group { active.formUnion(owners); complete = complete && succeeded }
            guard !Task.isCancelled else { return Self() }
            return Self(activeProfiles: active, checkedAt: now, complete: complete)
        }
    }
}
