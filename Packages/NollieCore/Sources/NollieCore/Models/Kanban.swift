import Foundation

// Models for Hermes's kanban plugin (under /api/plugins/kanban). Boards hold tasks for the bots.
// A task carries its text (title and body), the bot it is assigned to, a priority and a status. When a task's
// parents are done the gateway's dispatcher moves it from todo to ready, claims it and starts a
// worker. Incoming keys are snake_case; the shared decoder maps them.

// MARK: Status

/// A board column. They are shown in the order of `columns`; archived tasks only when asked for.
public enum KanbanStatus: String, CaseIterable, Hashable, Sendable, Codable {
    case triage
    case todo
    case scheduled
    case ready
    case running
    case blocked
    case review
    case done
    case archived

    /// The columns a board shows, left to right. Archived tasks are fetched only on request.
    public static let columns: [KanbanStatus] = allCases.filter { $0 != .archived }

    /// The statuses a person may drop a card on. The gateway sets scheduled, running and review itself.
    public static let moveTargets: [KanbanStatus] = allCases.filter { $0.gatewayOnlyNote == nil }

    /// What the page says about this status.
    private struct Look {
        let title: String
        let symbol: String
        /// Set for the statuses only the gateway can put a task into.
        var gatewayOnlyNote: String? = nil
    }

    private var look: Look {
        switch self {
        case .triage: Look(title: "Triage", symbol: "tray")
        case .todo: Look(title: "To do", symbol: "circle")
        case .ready: Look(title: "Ready", symbol: "play.circle")
        case .blocked: Look(title: "Blocked", symbol: "hand.raised")
        case .done: Look(title: "Done", symbol: "checkmark.circle")
        case .archived: Look(title: "Archived", symbol: "archivebox")
        case .scheduled:
            Look(title: "Scheduled", symbol: "calendar",
                 gatewayOnlyNote: "A task becomes Scheduled when it is given a time.")
        case .running:
            Look(title: "Running", symbol: "bolt.circle",
                 gatewayOnlyNote: "The dispatcher moves a task to Running when a worker picks it up.")
        case .review:
            Look(title: "Review", symbol: "eye",
                 gatewayOnlyNote: "A worker asks for Review when it hands the task over.")
        }
    }

    public var title: String { look.title }
    public var symbol: String { look.symbol }

    /// For a status a person can't move a card to, why not.
    public var notMovableReason: String? { gatewayOnlyNote }
    private var gatewayOnlyNote: String? { look.gatewayOnlyNote }

    public var isMoveTarget: Bool { gatewayOnlyNote == nil }

    /// Done wants a short explanation. Without a result or summary Hermes turns it down, except when
    /// the task came out of a review.
    public var asksForSummary: Bool { self == .done }

    /// Archiving or blocking is put to the person as a yes or no first.
    public var asksToConfirm: Bool { [.archived, .blocked].contains(self) }
}

// MARK: Small parts of a task

public struct KanbanAge: Codable, Sendable, Hashable {
    public let createdAgeSeconds: Int?
    public let startedAgeSeconds: Int?
    public let timeToCompleteSeconds: Int?
}

public struct KanbanLinkCounts: Codable, Sendable, Hashable {
    public let parents: Int
    public let children: Int
}

/// How many of a parent's children are done.
public struct KanbanProgress: Codable, Sendable, Hashable {
    public let done: Int
    public let total: Int
}

/// A note the gateway attaches to a card, such as a stuck worker or a tripped breaker. Its
/// fields differ by kind, so any of them may be missing; `text` picks the best one to show.
public struct KanbanDiagnostic: Codable, Sendable, Hashable {
    public let code: String?
    public let kind: String?
    public let severity: String?
    public let message: String?
    public let title: String?

    public var text: String {
        [message, title, code, kind].lazy.compactMap { $0 }.first ?? "Needs a look"
    }
}

// MARK: Task

public struct KanbanTask: Codable, Sendable, Identifiable, Hashable {
    public var priority: Int?
    public var createdAt: Int?
    public var startedAt: Int?
    public var completedAt: Int?
    public var workerPid: Int?
    public var lastHeartbeatAt: Int?
    public var currentRunId: Int?
    public var currentRunStartedAt: Int?
    public var consecutiveFailures: Int?
    public var maxRuntimeSeconds: Int?
    public var commentCount: Int?
    public var diagnostics: [KanbanDiagnostic]?
    public var id: String
    public var title: String
    public var status: String
    public var body: String?
    public var assignee: String?
    public var createdBy: String?
    public var tenant: String?
    public var result: String?
    /// Chat the task was created from, when a bot filed it. Empty for tasks made through the CLI or
    /// the dashboard.
    public var sessionId: String?
    public var blockKind: String?
    public var lastFailureError: String?
    public var projectId: String?
    public var workspaceKind: String?
    /// The newest run's hand-over note: cut to 200 characters on the board, whole in the detail.
    public var latestSummary: String?
    public var age: KanbanAge?
    public var linkCounts: KanbanLinkCounts?
    public var progress: KanbanProgress?

    public init(id: String,
                title: String,
                status: String,
                body: Optional<String> = nil,
                assignee: Optional<String> = nil,
                priority: Optional<Int> = nil,
                createdAt: Optional<Int> = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.body = body
        self.assignee = assignee
        self.priority = priority
        self.createdAt = createdAt
    }

    public var column: KanbanStatus? { KanbanStatus(rawValue: status) }

    public var created: Date? {
        createdAt.map { Date(timeIntervalSince1970: Double($0)) }
    }

    public var warnings: [KanbanDiagnostic] { diagnostics ?? [] }

    /// Blocked on something only the person can fix. Review, and waits that mend themselves
    /// (a dependency, a transient failure), are for the agents.
    public var needsUserAction: Bool {
        guard column == .blocked else { return false }
        return !["transient", "dependency"].contains(blockKind)
    }

    /// A worker has it right now.
    public var isWorking: Bool {
        guard column == .running else { return false }
        return workerPid != nil || currentRunStartedAt != nil || currentRunId != nil
    }

    /// Text beneath the title: the latest summary, falling back to the body's first line.
    public var preview: String? {
        if let latestSummary, !latestSummary.isEmpty { return latestSummary }
        guard let firstLine = body?.split(separator: "\n").first, !firstLine.isEmpty else { return nil }
        return String(firstLine)
    }
}

// MARK: Board

/// One column of a board: its status name and the tasks in it.
public struct KanbanColumn: Codable, Sendable, Hashable {
    public var tasks: [KanbanTask]
    public var name: String

    /// The status the column's name stands for, when it is one the app knows.
    public var status: KanbanStatus? { KanbanStatus(rawValue: name) }

    public init(name: String, tasks: [KanbanTask]) {
        self.tasks = tasks
        self.name = name
    }
}

public struct KanbanBoard: Codable, Sendable, Hashable {
    /// The server's clock when it answered, in epoch seconds.
    public var now: Int?
    /// The id of the newest event. The live socket starts from here so no history is replayed.
    public var latestEventId: Int?
    public var assignees: [String]?
    public var tenants: [String]?
    public var columns: [KanbanColumn]

    /// Every task on the board, column by column.
    public var allTasks: [KanbanTask] { columns.flatMap { $0.tasks } }

    public func tasks(in status: KanbanStatus) -> [KanbanTask] {
        columns.first { $0.status == status }?.tasks ?? []
    }

    public func count(_ status: KanbanStatus) -> Int {
        columns.first { $0.status == status }?.tasks.count ?? 0
    }

    public func task(id: String) -> KanbanTask? {
        for task in allTasks where task.id == id { return task }
        return nil
    }

    /// How many cards want someone to look: those blocked, plus any with a diagnostic.
    public var needsAttention: Int {
        var waiting = 0
        for task in allTasks where task.column == .blocked || !task.warnings.isEmpty { waiting += 1 }
        return waiting
    }

    public init(columns: Array<KanbanColumn>,
                tenants: Optional<[String]> = nil,
                assignees: Optional<[String]> = nil,
                latestEventId: Optional<Int> = nil,
                now: Optional<Int> = nil) {
        (self.now, self.latestEventId) = (now, latestEventId)
        (self.assignees, self.tenants) = (assignees, tenants)
        self.columns = columns
    }
}

/// A board as `/boards` lists it.
public struct KanbanBoardMeta: Codable, Sendable, Identifiable, Hashable {
    public var slug: String
    public var name: String?
    public var description: String?
    public var icon: String?
    public var color: String?
    public var projectName: String?
    public var counts: [String: Int]?
    public var total: Int?
    public var isCurrent: Bool?
    public var archived: Bool?

    public init(slug: String,
                name: Optional<String> = nil,
                isCurrent: Optional<Bool> = nil,
                counts: Optional<[String: Int]> = nil,
                total: Optional<Int> = nil) {
        self.slug = slug
        self.name = name
        self.isCurrent = isCurrent
        self.counts = counts
        self.total = total
    }

    public var id: String { slug }

    /// The board's name, or its slug if it has none.
    public var displayName: String {
        name.flatMap { $0.isEmpty ? nil : $0 } ?? slug
    }
}

public struct KanbanBoards: Codable, Sendable {
    public var boards: [KanbanBoardMeta]
    public var current: String?
}
