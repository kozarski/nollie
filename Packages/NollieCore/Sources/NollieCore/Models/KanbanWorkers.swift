import Foundation

// Who is working: the bots that can take tasks, the workers running now, logs and counts.

public struct KanbanStats: Codable, Sendable {
    public let byStatus: [String: Int]?
    public let byAssignee: [String: [String: Int]]?
}

public struct KanbanLog: Codable, Sendable {
    public let exists: Bool
    public let truncated: Bool?
    public let sizeBytes: Int?
    public let taskId: String?
    public let content: String
}

public struct KanbanWorkers: Codable, Sendable {
    public let workers: [KanbanWorker]
    public let count: Int?
    public let checkedAt: Int?
}

/// A worker that is running now, as `/workers/active` lists it.
public struct KanbanWorker: Codable, Sendable, Identifiable, Hashable {
    public let runId: Int
    public let workerPid: Int?
    public let startedAt: Int?
    public let lastHeartbeatAt: Int?
    public let taskId: String
    public let taskTitle: String?
    public let taskStatus: String?
    public let taskAssignee: String?
    public let profile: String?

    public var id: Int { runId }
}

struct KanbanAssignees: Codable, Sendable {
    let assignees: [KanbanAssignee]
}

public struct KanbanAssignee: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let onDisk: Bool?
    public let counts: [String: Int]?

    public var id: String { name }
}
