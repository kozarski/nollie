import Foundation

// The REST side of the demo gateway: the dashboard routes the app reads and writes.

extension DemoGateway {

    /// Answers one request. `target` is the path and query as the request line has them.
    public func rest(_ method: String, _ target: String, body: Data?) -> (status: Int, body: Data) {
        let parts = URLComponents(string: target)
        let path = parts?.path ?? target
        var query: [String: String] = [:]
        for item in parts?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let sent = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? [:]
        let (status, answer) = route(method, path, query, sent)
        return (status, (try? JSONEncoder().encode(answer)) ?? Data("{}".utf8))
    }

    func refuse(_ status: Int, _ words: String) -> (Int, JSONValue) { (status, ["detail": .string(words)]) }

    func route(_ method: String, _ path: String, _ query: [String: String], _ body: JSONValue) -> (Int, JSONValue) {
        let now = Date().timeIntervalSince1970.rounded(.down)
        let pieces = path.split(separator: "/").map(String.init)
        switch path {
        case "/api/status": return (200, DemoRoutes.status())
        case "/api/health": return (200, ["ok": true, "version": "demo", "auth_required": false])
        case "/api/profiles": return (200, DemoRoutes.profiles())
        case "/api/profiles/active": return (200, ["active": "default", "current": "default"])
        case "/api/model/options": return (200, DemoRoutes.modelOptions())
        case "/api/config": return (200, ["config": DemoRoutes.config])
        case "/api/hermes/update/check":
            return (200, ["install_method": "git", "current_version": "demo", "behind": 0, "update_available": false,
                          "can_apply": false, "update_command": "", "message": nil, "commits": []])
        case "/api/skills", "/api/tools/toolsets": return (200, [])
        case "/api/mcp/servers": return (200, ["servers": []])
        case "/api/plugins/nollie-workflow/private-bots": return (200, ["profiles": [], "saved": true])
        case "/api/plugins/nollie-workflow/attention":
            return (200, ["counts": ["default": .number(Double(kanban.waiting()))]])
        case "/api/plugins/nollie-workflow/posts": return (200, DemoRoutes.posts(now: now))
        case "/api/plugins/nollie-workflow/night-shift":
            if method == "PUT", let on = body["on"]?.boolValue { nightShiftOn = on }
            return (200, ["on": .bool(nightShiftOn), "damaged": false])
        case "/api/plugins/nollie-workflow/papertrail":
            let bot = query["bot"] ?? "default"
            guard let view = DemoRoutes.papertrail(bot: bot, days: Int(query["days"] ?? "") ?? 1, now: now) else {
                return refuse(404, "Papertrail is not on for this bot.")
            }
            return (200, view)
        case "/api/plugins/nollie-workflow/week":
            return (200, DemoRoutes.week(bot: query["bot"] ?? "default", now: now))
        case "/api/plugins/nollie-workflow/week/switch":
            return (200, ["bot": body["bot"] ?? "default", "kind": body["kind"] ?? "web", "name": body["name"] ?? nil,
                          "on": body["on"] ?? true])
        case "/api/plugins/nollie-computer/ask-first":
            let bot = query["profile"] ?? "default"
            if method == "PUT" { askFirst[bot] = body["enabled"]?.boolValue ?? true }
            return (200, ["profile": .string(bot), "enabled": .bool(askFirst[bot] ?? true)])
        case "/api/sessions": return (200, sessionsList())
        case "/api/sessions/search":
            let needle = (query["q"] ?? "").lowercased()
            let found = chats.filter { chat in
                needle.isEmpty || chat.title.lowercased().contains(needle) || chat.rows.contains { $0.text.lowercased().contains(needle) }
            }
            return (200, ["sessions": .array(found.map(sessionRow))])
        case "/api/sessions/stats":
            return (200, ["total": .number(Double(chats.count)), "active_store": .number(Double(chats.count)), "archived": 0,
                          "messages": .number(Double(chats.reduce(0) { $0 + $1.rows.count })), "by_source": ["ios": .number(Double(chats.count))]])
        case "/api/cron/jobs":
            if method == "POST" { return createSchedule(body, bot: query["profile"]) }
            return (200, ["count": .number(Double(schedules.count)), "jobs": .array(schedules)])
        default: break
        }

        if pieces.count == 4, pieces[1] == "profiles", pieces[3] == "soul" {
            return (200, ["content": "# Notes\n\nA friendly helper.", "exists": true])
        }
        if pieces.count >= 3, pieces[1] == "sessions" { return sessionRoute(method, pieces, query, body) }
        if pieces.count >= 4, pieces[1] == "plugins", pieces[2] == "kanban" { return kanbanRoute(method, Array(pieces.dropFirst(3)), body) }
        if pieces.count >= 3, pieces[1] == "cron", pieces[2] == "jobs" { return scheduleRoute(method, pieces, body) }
        // Anything else is not part of the demo. An empty answer lets a page show its empty state.
        return (200, [:])
    }

    // MARK: Chats

    private func sessionsList() -> JSONValue {
        let rows = chats.filter { !$0.rows.isEmpty }
            .sorted { $0.lastActive > $1.lastActive }
        return ["sessions": .array(rows.map(sessionRow)), "total": .number(Double(rows.count)), "limit": 100, "offset": 0]
    }

    private func sessionRoute(_ method: String, _ pieces: [String], _ query: [String: String], _ body: JSONValue) -> (Int, JSONValue) {
        let id = pieces[2]
        guard let at = chatIndex(id) else { return refuse(404, "session not found") }
        if pieces.count == 4, pieces[3] == "messages" {
            let wanted = Int(query["limit"] ?? "") ?? 60
            let rows = Array(chats[at].rows.suffix(wanted))
            return (200, ["session_id": .string(id), "profile": .string(chats[at].profile), "messages": .array(rows.map(Self.pageRow)),
                          "pagination": ["limit": .number(Double(wanted)), "offset": 0, "order": "latest", "returned": .number(Double(rows.count))]])
        }
        guard pieces.count == 3 else { return (200, [:]) }
        switch method {
        case "PATCH":
            if let words = body["title"]?.stringValue, !words.isEmpty { chats[at].title = words }
            if let flag = body["pinned"]?.boolValue { chats[at].pinned = flag }
            if let flag = body["archived"]?.boolValue { chats[at].archived = flag }
            return (200, ["ok": true, "title": .string(chats[at].title)])
        case "DELETE":
            chats.remove(at: at)
            return (200, ["ok": true, "deleted": true])
        default:
            let asking = query["profile"] ?? "default"
            guard chats[at].profile == asking else { return refuse(404, "session not found") }
            return (200, sessionRow(chats[at]))
        }
    }

    // MARK: Schedules

    private func createSchedule(_ body: JSONValue, bot: String?) -> (Int, JSONValue) {
        guard let prompt = body["prompt"]?.stringValue, !prompt.isEmpty, let when = body["schedule"]?.stringValue, !when.isEmpty else {
            return refuse(400, "A prompt and schedule are required.")
        }
        let job: JSONValue = [
            "job_id": .string("demo-" + UUID().uuidString.prefix(8).lowercased()), "name": .string(body["name"]?.stringValue ?? ""),
            "schedule": .string(when), "prompt": .string(prompt), "prompt_preview": .string(String(prompt.prefix(80))), "deliver": "local",
            "enabled": true, "state": "active", "profile": .string(bot ?? body["profile"]?.stringValue ?? "default"),
        ]
        schedules.append(job)
        return (200, job)
    }

    private func scheduleRoute(_ method: String, _ pieces: [String], _ body: JSONValue) -> (Int, JSONValue) {
        let ref = pieces[3]
        guard let at = schedules.firstIndex(where: { $0["job_id"]?.stringValue == ref }) else { return refuse(404, "job not found") }
        if method == "DELETE" {
            schedules.remove(at: at)
            return (200, ["ok": true])
        }
        guard var job = schedules[at].objectValue else { return (200, [:]) }
        switch pieces.count > 4 ? pieces[4] : "" {
        case "pause": job["enabled"] = false; job["state"] = "paused"
        case "resume": job["enabled"] = true; job["state"] = "active"
        case "trigger": job["last_status"] = "ok"
        default:
            for (key, value) in body.objectValue ?? [:] { job[key] = value }
        }
        schedules[at] = .object(job)
        return (200, .object(job))
    }

    // MARK: Board

    private func kanbanRoute(_ method: String, _ pieces: [String], _ body: JSONValue) -> (Int, JSONValue) {
        switch pieces[0] {
        case "boards": return (200, kanban.boards())
        case "board": return (200, kanban.board())
        case "assignees": return (200, kanban.assignees())
        case "workers": return (200, kanban.workers())
        case "stats": return (200, ["by_status": .object(kanban.counts()), "by_assignee": [:], "oldest_ready_age_seconds": 5_400])
        case "dispatch": return (200, ["spawned": 0, "promoted": 0, "reasons": [], "dry_run": false])
        case "tasks":
            if pieces.count == 1 {
                guard method == "POST" else { return (200, [:]) }
                return (200, kanban.add(body))
            }
            return kanbanTask(method, pieces[1], pieces.count > 2 ? pieces[2] : "", body)
        default: return (200, [:])
        }
    }

    private func kanbanTask(_ method: String, _ id: String, _ tail: String, _ body: JSONValue) -> (Int, JSONValue) {
        guard let detail = kanban.detail(id) else { return refuse(404, "task \(id) not found") }
        switch tail {
        case "comments":
            kanban.comment(id, body)
            return (200, ["ok": true])
        case "reassign":
            _ = kanban.edit(id, ["assignee": body["profile"] ?? nil])
            return (200, ["ok": true, "task_id": .string(id), "assignee": body["profile"] ?? nil])
        case "reclaim": return (200, ["ok": true, "task_id": .string(id)])
        case "log":
            return (200, ["task_id": .string(id), "path": "", "exists": false, "size_bytes": 0, "content": "", "truncated": false])
        case "":
            switch method {
            case "PATCH":
                let done = kanban.edit(id, body)
                if let why = done.refusal { return refuse(409, why) }
                return (200, ["task": done.task ?? nil])
            case "DELETE":
                kanban.remove(id)
                return (200, ["deleted": true, "task_id": .string(id)])
            default: return (200, detail)
            }
        default: return (200, [:])
        }
    }
}
