import Foundation

// What the task page shows besides the card: its detail, history, runs and links.

/// A task with its history: comments, what happened to it, each run, and how it is linked.
public struct KanbanTaskDetail: Codable, Sendable {
    public var task: KanbanTask
    public var comments: [KanbanComment] = []
    public var events: [KanbanEvent] = []
    public var runs: [KanbanRun] = []
    public var links: KanbanLinks?
    public var childResults: [KanbanChildResult]?

    /// The run in progress: the last open one, else the one the task points at.
    public var currentRun: KanbanRun? {
        let stillOpen = runs.reversed().first { $0.isOpen }
        return stillOpen ?? runs.first { $0.id == task.currentRunId }
    }
}

public struct KanbanChildResult: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let status: String
    public let latestSummary: String?
    public let result: String?
}

public struct KanbanLinks: Codable, Sendable, Hashable {
    public let parents: [String]
    public let children: [String]
}

/// One go at a task. It opens when a worker claims the task and closes when the worker
/// finishes, blocks, crashes, runs out of time, or is reclaimed.
public struct KanbanRun: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let startedAt: Int
    public let endedAt: Int?
    public let taskId: String?
    public let profile: String?
    public let stepKey: String?
    public let status: String?
    public let outcome: String?
    public let summary: String?
    public let error: String?
    public let workerPid: Int?
    public let maxRuntimeSeconds: Int?
    public let lastHeartbeatAt: Int?

    public var isOpen: Bool { endedAt == nil }

    public var started: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }

    /// How long it has run, or ran for.
    public var durationSeconds: Int {
        (endedAt ?? Int(Date().timeIntervalSince1970)) - startedAt
    }

    /// "running" while open, afterwards how it ended ("completed", "blocked", "crashed"...).
    public var stateText: String {
        guard !isOpen else { return "running" }
        return outcome ?? status ?? "ended"
    }
}

public struct KanbanEvent: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    /// Missing for events about the board as a whole. One such event once failed the decoding
    /// of a whole frame, and the board stopped refreshing.
    public let taskId: String?
    public let runId: Int?
    /// What happened: "status", "commented", "blocked", "reclaimed", "edited" and so on.
    public let kind: String
    public let payload: JSONValue?
    public let createdAt: Int

    public var created: Date { Date(timeIntervalSince1970: Double(createdAt)) }

    /// Wording for the kinds that read well as they are. Kinds not listed get their own cases below.
    private static let wording: [(kind: String, text: String)] = [
        ("attached", "File added"),
        ("unlinked", "Link taken off"),
        ("archived", "Put away"),
        ("scheduled", "Given a time"),
        ("edited", "Details changed"),
        ("reprioritized", "Priority set again"),
        ("promoted_manual", "Moved up by hand"),
        ("claim_rejected", "Claim turned down"),
        ("reclaimed", "Worker taken back"),
        ("review_requested", "Review requested"),
        ("commented", "Comment"),
    ]

    /// A few words for a row in the task's timeline.
    public var line: String {
        if let hit = Self.wording.first(where: { $0.kind == kind }) { return hit.text }
        if kind == "status" {
            let target = payload?["to"]?.stringValue ?? payload?["status"]?.stringValue
            guard let target else { return "Status changed" }
            return "Moved to \(KanbanStatus(rawValue: target)?.title ?? target)"
        }
        if kind == "blocked" {
            return payload?["reason"]?.stringValue.map { "Blocked: \($0)" } ?? "Blocked"
        }
        let words = kind.split(separator: "_").joined(separator: " ")
        return words.capitalized
    }
}

public struct KanbanComment: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let author: String
    public let body: String
    public let taskId: String?
    public let createdAt: Int

    public var created: Date { Date(timeIntervalSince1970: Double(createdAt)) }
}
