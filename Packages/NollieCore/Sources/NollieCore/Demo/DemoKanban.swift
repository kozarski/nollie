import Foundation

/// The demo's Board: one board of a few cards for the four bots, kept in memory and changed by
/// what the person does to it (moving a card, adding one, leaving a comment).
struct DemoKanban {
    static let columns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

    var tasks: [[String: JSONValue]]
    var comments: [String: [JSONValue]] = [:]
    var cursor = 1
    private var nextID = 20
    let now: Double

    /// Whole seconds: the plugin's times are integers, and the app reads them as such.
    static func stamp() -> Double { Date().timeIntervalSince1970.rounded(.down) }

    init(now: Double) {
        self.now = now.rounded(.down)
        let now = self.now
        tasks = [
            Self.task("k-1", "Plan Saturday and Sunday", "running", "default", now: now, priority: 1, createdAgo: 9_000, startedAgo: 1_200,
                      body: "Keep it under £40 for two, with a dry plan for Saturday and a rainy one for Sunday.",
                      summary: "Sketched both days; looking for three places to add."),
            Self.task("k-2", "Shortlist gifts under £30", "ready", "scout", now: now, createdAgo: 6_000,
                      body: "For Mum, who loves gardening."),
            Self.task("k-3", "Compare the Aero 5 and the Dustpro 300", "review", "scout", now: now, createdAgo: 12_000, startedAgo: 9_000,
                      summary: "Draft is ready for a look."),
            Self.task("k-4", "Send Sam the Thursday note", "blocked", "mason", now: now, createdAgo: 2_400, startedAgo: 2_000,
                      body: "Hi Sam, I can meet at 10 on Thursday. See you then.", summary: "Waiting for your yes to send."),
            Self.task("k-5", "Plan my day", "done", "wren", now: now, createdAgo: 20_000, startedAgo: 19_000, completedAgo: 18_000,
                      result: "A plan for the call at 10, the dentist at 3 and a run at 5:30."),
            Self.task("k-6", "Watch the Aero 5 price", "scheduled", "scout", now: now, createdAgo: 40_000),
            Self.task("k-7", "Ideas for a rainy Sunday", "triage", nil, now: now, createdAgo: 600),
        ]
        comments["k-4"] = [["id": 1, "task_id": "k-4", "author": "mason", "body": "Ready to send once you say yes.", "created_at": .number(now - 1_900)]]
        tasks[3]["comment_count"] = 1
    }

    /// A task as the plugin lists it. The `*Ago` arguments are seconds before now.
    static func task(_ id: String, _ title: String, _ status: String, _ assignee: String?, now: Double, priority: Int = 0,
                     createdAgo: Double = 7_200, startedAgo: Double? = nil, completedAgo: Double? = nil, body: String? = nil,
                     summary: String? = nil, result: String? = nil) -> [String: JSONValue] {
        let running = status == "running"
        func at(_ ago: Double?) -> JSONValue { ago.map { .number(now - $0) } ?? .null }
        func text(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
        var row: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "body": text(body), "assignee": text(assignee), "status": .string(status),
            "priority": .number(Double(priority)), "created_by": "dashboard", "workspace_kind": "scratch", "workspace_path": nil,
            "branch_name": nil, "project_id": nil, "worker_pid": running ? 4242 : nil, "current_run_id": running ? 1 : nil,
            "max_runtime_seconds": 3600, "last_heartbeat_at": running ? .number(now - 12) : nil, "consecutive_failures": 0,
            "last_failure_error": nil, "claim_lock": running ? .string("w-\(id)") : nil,
            "claim_expires": running ? .number(now + 3600) : nil, "idempotency_key": nil, "workflow_template_id": nil,
            "current_step_key": nil, "skills": nil, "model_override": nil, "provider_override": nil, "reasoning_effort": nil,
            "max_retries": nil, "goal_max_turns": nil, "block_kind": nil, "completion_contract": nil, "goal_mode": false,
            "block_recurrences": 0, "created_at": at(createdAgo), "started_at": at(startedAgo), "completed_at": at(completedAgo),
            "tenant": nil, "result": text(result), "session_id": nil, "latest_summary": text(summary), "comment_count": 0,
            "progress": nil, "current_run_started_at": running ? at(startedAgo) : nil,
            "link_counts": ["parents": 0, "children": 0],
            "age": ["created_age_seconds": .number(createdAgo), "started_age_seconds": startedAgo.map { .number($0) } ?? .null,
                    "time_to_complete_seconds": (completedAgo != nil && startedAgo != nil) ? .number(startedAgo! - completedAgo!) : .null],
        ]
        if status == "blocked" { row["block_kind"] = "human" }
        return row
    }

    // MARK: Reading

    func counts() -> [String: JSONValue] {
        var found: [String: Int] = [:]
        for task in tasks { found[task["status"]?.stringValue ?? "", default: 0] += 1 }
        return found.mapValues { .number(Double($0)) }
    }

    func boards() -> JSONValue {
        let board: JSONValue = [
            "slug": "default", "name": "Home", "description": "", "created_at": nil, "project_name": nil, "icon": "", "color": "",
            "default_workdir": nil, "project_id": nil, "archived": false, "default_workspace_kind": "scratch", "is_current": true,
            "counts": .object(counts()), "total": .number(Double(tasks.count)),
        ]
        return ["boards": [board], "current": "default"]
    }

    func board() -> JSONValue {
        let columns = Self.columns.map { name -> JSONValue in
            ["name": .string(name), "tasks": .array(tasks.filter { $0["status"]?.stringValue == name }.map { .object($0) })]
        }
        let people = Set(tasks.compactMap { $0["assignee"]?.stringValue }).sorted()
        return ["columns": .array(columns), "tenants": [], "assignees": .array(people.map { .string($0) }),
                "latest_event_id": .number(Double(cursor)), "now": .number(Self.stamp())]
    }

    func workers() -> JSONValue {
        let busy = tasks.filter { $0["status"]?.stringValue == "running" }.map { task -> JSONValue in
            ["run_id": task["current_run_id"] ?? 1, "task_id": task["id"] ?? "", "task_title": task["title"] ?? "", "task_status": "running",
             "task_assignee": task["assignee"] ?? nil, "profile": task["assignee"] ?? nil, "max_runtime_seconds": 3600,
             "claim_lock": task["claim_lock"] ?? nil, "claim_expires": task["claim_expires"] ?? nil,
             "last_heartbeat_at": task["last_heartbeat_at"] ?? nil, "worker_pid": task["worker_pid"] ?? nil, "started_at": task["started_at"] ?? nil]
        }
        return ["checked_at": .number(Self.stamp()), "count": .number(Double(busy.count)), "workers": .array(busy)]
    }

    func assignees() -> JSONValue {
        ["assignees": .array(DemoSeed.bots.map { ["name": .string($0.name), "on_disk": true, "counts": [:]] })]
    }

    func detail(_ id: String) -> JSONValue? {
        guard let task = tasks.first(where: { $0["id"]?.stringValue == id }) else { return nil }
        return ["task": .object(task), "attachments": [], "link_tasks": [:], "child_results": [],
                "comments": .array(comments[id] ?? []), "events": [], "runs": [], "links": ["parents": [], "children": []]]
    }

    /// How many blocked tasks wait on a person, for the Board tab's badge.
    func waiting() -> Int {
        tasks.filter { $0["status"]?.stringValue == "blocked" }.count
    }

    // MARK: Changing

    private func index(_ id: String) -> Int? {
        tasks.firstIndex { $0["id"]?.stringValue == id }
    }

    /// A change to a task. Returns the task, or the reason the server would refuse.
    mutating func edit(_ id: String, _ patch: JSONValue) -> (task: JSONValue?, refusal: String?) {
        guard let at = index(id) else { return (nil, "task \(id) not found") }
        if let assignee = patch["assignee"] { tasks[at]["assignee"] = assignee }
        if let status = patch["status"]?.stringValue {
            if status == "running" { return (nil, "the dispatcher moves a task to running once a worker picks it up") }
            let outcome = patch["result"]?.stringValue ?? patch["summary"]?.stringValue ?? tasks[at]["result"]?.stringValue
            if status == "done", tasks[at]["status"]?.stringValue != "review", outcome == nil {
                return (nil, "a task reaches done from review, or when it has a result or summary")
            }
            tasks[at]["status"] = .string(status)
            if status == "done" {
                tasks[at]["completed_at"] = .number(Self.stamp())
                tasks[at]["result"] = outcome.map { .string($0) } ?? .null
            }
        }
        for field in ["title", "body", "priority"] {
            if let value = patch[field], !(value.isNull && field == "title") { tasks[at][field] = value }
        }
        cursor += 1
        return (.object(tasks[at]), nil)
    }

    mutating func add(_ payload: JSONValue) -> JSONValue {
        nextID += 1
        let triage = payload["triage"]?.boolValue == true
        let assignee = payload["assignee"]?.stringValue
        var row = Self.task("k-\(nextID)", payload["title"]?.stringValue ?? "New task", triage ? "triage" : (assignee == nil ? "todo" : "ready"),
                            assignee, now: Self.stamp(), priority: payload["priority"]?.intValue ?? 0, createdAgo: 0,
                            body: payload["body"]?.stringValue)
        row["created_at"] = .number(Self.stamp())
        tasks.append(row)
        cursor += 1
        return ["task": .object(row), "ok": true]
    }

    mutating func comment(_ id: String, _ payload: JSONValue) {
        guard let at = index(id) else { return }
        let number = comments.values.reduce(0) { $0 + $1.count } + 1
        comments[id, default: []].append(["id": .number(Double(number)), "task_id": .string(id),
                                          "author": .string(payload["author"]?.stringValue ?? "dashboard"),
                                          "body": .string(payload["body"]?.stringValue ?? ""),
                                          "created_at": .number(Self.stamp())])
        tasks[at]["comment_count"] = .number(Double(comments[id]?.count ?? 0))
        cursor += 1
    }

    mutating func remove(_ id: String) {
        tasks.removeAll { $0["id"]?.stringValue == id }
        cursor += 1
    }
}
