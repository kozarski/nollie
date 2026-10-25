import Foundation

// What goes to the kanban plugin, what it answers a write with, and how the live socket's
// position is tracked.

/// A task to create.
public struct KanbanNewTask: Sendable, Equatable, Encodable {
    public var title: String
    public var priority: Int = 0
    public var triage = false
    public var parents: [String] = []
    public var body: String? = nil
    public var assignee: String? = nil
    public var tenant: String? = nil

    private enum CodingKeys: String, CodingKey { case title, body, assignee, tenant, priority, parents, triage }

    /// Blank text fields are left out of the request, not sent empty.
    public func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: CodingKeys.self)
        try out.encode(title, forKey: .title)
        try out.encode(priority, forKey: .priority)
        try out.encode(parents, forKey: .parents)
        try out.encode(triage, forKey: .triage)
        let optional: [(CodingKeys, String?)] = [(.body, body), (.assignee, assignee), (.tenant, tenant)]
        for case (let key, let text?) in optional where !text.isEmpty {
            try out.encode(text, forKey: key)
        }
    }

    var json: JSONValue { (try? JSONValue.encode(self)) ?? .object([:]) }

    public init(title: String,
                body: Optional<String> = nil,
                assignee: Optional<String> = nil,
                tenant: Optional<String> = nil,
                priority: Int = 0,
                parents: Array<String> = [],
                triage: Bool = false) {
        self.title = title
        self.body = body
        self.assignee = assignee
        self.tenant = tenant
        self.priority = priority
        self.parents = parents
        self.triage = triage
    }
}

/// An edit to a task. Only fields that are set go out; setting `status` moves the card.
public struct KanbanTaskPatch: Sendable, Equatable, Encodable {
    public var status: KanbanStatus? = nil
    /// Outer nil leaves the assignee alone; `.some(nil)` takes it off.
    public var assignee: String?? = nil
    public var priority: Int? = nil
    public var title: String? = nil
    public var body: String? = nil
    public var result: String? = nil
    public var summary: String? = nil
    public var blockReason: String? = nil

    private enum CodingKeys: String, CodingKey {
        case status, assignee, priority, title, body, result, summary, blockReason
    }

    public func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: CodingKeys.self)
        try out.encodeIfPresent(status, forKey: .status)
        try out.encodeIfPresent(priority, forKey: .priority)
        for (key, text) in [(CodingKeys.title, title), (.body, body), (.result, result), (.summary, summary), (.blockReason, blockReason)] {
            try out.encodeIfPresent(text, forKey: key)
        }
        // A given assignee of nil is sent as null, which takes the assignee off.
        if let change = assignee { try out.encode(change, forKey: .assignee) }
    }

    var json: JSONValue { (try? JSONValue.encode(self)) ?? .object([:]) }
}

/// A write's answer: the task as it is now and, after a create, the dispatcher's warning when
/// nothing is running that would pick the task up.
public struct KanbanTaskEnvelope: Codable, Sendable {
    /// Set only when the create found no dispatcher to run the card.
    public var warning: String?
    /// The card after the write; absent when the server had nothing to show.
    public var task: KanbanTask?
}

/// A message from the `/events` socket: events after the cursor, plus the next cursor.
public struct KanbanEventsFrame: Codable, Sendable, Equatable {
    public var cursor: Int
    public var events: [KanbanEvent]

    public init(events: [KanbanEvent], cursor: Int) {
        self.events = events
        self.cursor = cursor
    }
}

/// Where the live socket is up to, as the newest event id seen. Starting from the board's
/// `latest_event_id` skips replaying history, and every frame moves it forward.
public struct KanbanEventCursor: Sendable, Equatable {
    private var newest: Int?

    public init(start: Int? = nil) { newest = start }

    public var cursor: Int? { newest }

    /// The `since` parameter for opening the socket, once a position is known.
    public var sinceQuery: URLQueryItem? {
        guard let newest else { return nil }
        return URLQueryItem(name: "since", value: "\(newest)")
    }

    /// Takes the position from a board that was just read, if none is known yet.
    public mutating func start(fromBoard latest: Int?) {
        newest = newest ?? latest
    }

    /// Accepts a frame, and says whether it brought events (so the board should be re-read).
    public mutating func take(_ frame: KanbanEventsFrame) -> Bool {
        newest = [newest ?? 0, frame.cursor].max()
        return frame.events.count > 0
    }
}

/// Wrapper over the plugin's endpoints. A `?board=` parameter is added once a board has been
/// chosen. If the server refuses, the error is `HermesAPIError.http(status:detail:)` and `detail`
/// carries its message.
public struct KanbanAPI: Sendable {
    let api: HermesAPI
    /// The board to read and write; nil means the server's current one.
    public var board: String?

    public static let base = "/api/plugins/kanban"

    public init(api: HermesAPI, board: String? = nil) {
        (self.board, self.api) = (board, api)
    }

    // MARK: Routes

    private enum Route {
        case boardList, board, stats, workers, assignees, newTask, dispatch
        case task(String), taskLog(String), comments(String), reassign(String), reclaim(String)
        case run(Int), endRun(Int)

        /// The path after the plugin's base.
        var path: String {
            switch self {
            case .boardList: "/boards"
            case .board: "/board"
            case .stats: "/stats"
            case .workers: "/workers/active"
            case .assignees: "/assignees"
            case .newTask: "/tasks"
            case .dispatch: "/dispatch"
            case .task(let id): "/tasks/\(id)"
            case .taskLog(let id): "/tasks/\(id)/log"
            case .comments(let id): "/tasks/\(id)/comments"
            case .reassign(let id): "/tasks/\(id)/reassign"
            case .reclaim(let id): "/tasks/\(id)/reclaim"
            case .run(let id): "/runs/\(id)"
            case .endRun(let id): "/runs/\(id)/terminate"
            }
        }

        /// Only the list of boards is asked for without naming one.
        var isBoardScoped: Bool {
            if case .boardList = self { return false }
            return true
        }
    }

    private func address(_ route: Route) -> String { Self.base + route.path }

    /// The query for a route: the chosen board first (when the route has one), then the extras.
    private func items(for route: Route, _ extras: [URLQueryItem] = []) -> [URLQueryItem] {
        guard route.isBoardScoped, let board else { return extras }
        return [URLQueryItem(name: "board", value: board)] + extras
    }

    private func read<T: Decodable & Sendable>(_ route: Route, _ extras: [URLQueryItem] = []) async throws -> T {
        try await api.get(address(route), query: items(for: route, extras))
    }

    private func write<T: Decodable & Sendable>(_ verb: String, _ route: Route, _ extras: [URLQueryItem] = [], body: JSONValue) async throws -> T {
        try await api.send(verb, address(route), query: items(for: route, extras), json: body)
    }

    private func post(_ route: Route, _ fields: [String: JSONValue]) async throws {
        let _: JSONValue = try await write("POST", route, body: .object(fields))
    }

    private static func flag(_ name: String, _ isOn: Bool) -> URLQueryItem {
        URLQueryItem(name: name, value: isOn ? "true" : "false")
    }

    // MARK: Reading

    public func boards(includeArchived: Bool = false) async throws -> KanbanBoards {
        try await read(.boardList, [Self.flag("include_archived", includeArchived)])
    }

    public func board(includeArchived: Bool = false) async throws -> KanbanBoard {
        try await read(.board, [Self.flag("include_archived", includeArchived)])
    }

    public func task(_ id: String) async throws -> KanbanTaskDetail {
        try await read(.task(id))
    }

    public func log(_ id: String) async throws -> KanbanLog {
        try await log(id, tail: 20_000)
    }

    /// The last `tail` bytes of a task's log.
    public func log(_ id: String, tail bytes: Int) async throws -> KanbanLog {
        try await read(.taskLog(id), [URLQueryItem(name: "tail", value: "\(bytes)")])
    }

    public func workers() async throws -> KanbanWorkers {
        try await read(.workers)
    }

    public func assignees() async throws -> [KanbanAssignee] {
        let listing: KanbanAssignees = try await read(.assignees)
        return listing.assignees
    }

    public func stats() async throws -> KanbanStats {
        try await read(.stats)
    }

    public func run(_ id: Int) async throws -> KanbanRun {
        struct Wrapper: Decodable, Sendable { var run: KanbanRun }
        let wrapped: Wrapper = try await read(.run(id))
        return wrapped.run
    }

    // MARK: Writing

    public func create(_ task: KanbanNewTask) async throws -> KanbanTaskEnvelope {
        try await write("POST", .newTask, body: task.json)
    }

    @discardableResult
    public func update(_ id: String, _ patch: KanbanTaskPatch) async throws -> KanbanTaskEnvelope {
        try await write("PATCH", .task(id), body: patch.json)
    }

    public func delete(_ id: String) async throws {
        let route = Route.task(id)
        _ = try await api.raw("DELETE", address(route), query: items(for: route), profile: nil, body: nil, authenticated: true)
    }

    public func comment(_ id: String, _ body: String) async throws {
        try await comment(id, body, author: "nollie")
    }

    public func comment(_ id: String, _ body: String, author name: String) async throws {
        try await post(.comments(id), ["author": .string(name), "body": .string(body)])
    }

    public func reassign(_ id: String, to newOwner: String?, reclaimFirst: Bool, reason: String? = nil) async throws {
        var fields = Self.reasonFields(reason)
        fields["profile"] = newOwner.map { .string($0) } ?? .null
        fields["reclaim_first"] = .bool(reclaimFirst)
        try await post(.reassign(id), fields)
    }

    public func terminate(run: Int, reason: String? = nil) async throws {
        try await post(.endRun(run), Self.reasonFields(reason))
    }

    public func reclaim(_ id: String, reason: String? = nil) async throws {
        try await post(.reclaim(id), Self.reasonFields(reason))
    }

    /// Nudges the dispatcher so the board needn't wait for its 60 second tick.
    @discardableResult
    public func dispatch(max: Int = 8) async throws -> JSONValue {
        try await write("POST", .dispatch, [URLQueryItem(name: "max", value: String(max))], body: .object([:]))
    }

    private static func reasonFields(_ reason: String?) -> [String: JSONValue] {
        reason.map { ["reason": .string($0)] } ?? [:]
    }
}
