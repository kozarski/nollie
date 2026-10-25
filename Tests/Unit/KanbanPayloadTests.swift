import Foundation
import Testing
@testable import NollieCore

/// Sample replies from the Board plugin, shaped as its dashboard API delivers them.
@Suite struct KanbanPayloadTests {
    private static let boardJSON = """
    {"columns": [
      {"name": "triage", "tasks": []},
      {"name": "todo", "tasks": [{"id": "k-20", "title": "Trim the cache folder", "body": "keep 5", "assignee": "default", "status": "todo", "priority": 1,
        "created_by": "dashboard", "created_at": 1760000000, "started_at": null, "completed_at": null, "workspace_kind": "scratch", "workspace_path": null,
        "claim_lock": null, "claim_expires": null, "tenant": null, "age": {"created_age_seconds": 1800, "started_age_seconds": null, "time_to_complete_seconds": null},
        "latest_summary": null, "current_run_started_at": null, "link_counts": {"parents": 1, "children": 0}, "comment_count": 3, "progress": null}]},
      {"name": "running", "tasks": [{"id": "k-10", "title": "Sweep temp files", "body": null, "assignee": "career", "status": "running", "priority": 0,
        "created_by": "agent", "created_at": 1759990000, "started_at": 1760001000, "completed_at": null, "workspace_kind": "scratch", "workspace_path": null,
        "claim_lock": "w9", "claim_expires": 1760100000, "tenant": "home", "worker_pid": 5151, "last_heartbeat_at": 1760001300, "current_run_id": 12,
        "session_id": "20261001_101010_ab12cd", "age": {"created_age_seconds": 11000, "started_age_seconds": 300, "time_to_complete_seconds": null},
        "latest_summary": "Found 12 files", "current_run_started_at": 1760001000, "link_counts": {"parents": 0, "children": 1}, "comment_count": 0,
        "progress": {"done": 2, "total": 5}, "diagnostics": [{"code": "stale_heartbeat", "severity": "warning", "message": "No heartbeat for 9 minutes"}]}]},
      {"name": "done", "tasks": []}],
     "tenants": ["home"], "assignees": ["default", "career"], "latest_event_id": 77, "now": 1760001600}
    """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }

    @Test func aBoardCarriesEachCardsFacts() throws {
        let board = try decode(KanbanBoard.self, Self.boardJSON)
        #expect(board.columns.count == 4)
        #expect(board.latestEventId == 77)
        #expect(board.count(.todo) == 1 && board.count(.running) == 1 && board.count(.done) == 0)

        let busy = try #require(board.task(id: "k-10"))
        #expect(busy.column == .running && busy.isWorking)
        #expect(busy.workerPid == 5151 && busy.currentRunId == 12)
        #expect(busy.sessionId == "20261001_101010_ab12cd")
        #expect(busy.progress == KanbanProgress(done: 2, total: 5))
        #expect(busy.warnings.first?.text == "No heartbeat for 9 minutes")
        #expect(busy.preview == "Found 12 files")

        let waiting = try #require(board.task(id: "k-20"))
        #expect(waiting.priority == 1 && waiting.commentCount == 3 && waiting.linkCounts?.parents == 1)
        #expect(waiting.preview == "keep 5")
        #expect(!waiting.isWorking && waiting.age?.createdAgeSeconds == 1800)
        #expect(board.needsAttention == 1)
    }

    /// The same decoding, from a value built in Swift rather than written out as text.
    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONCoding.decoder.decode(type, from: JSONEncoder().encode(value))
    }

    @Test func aTaskDetailCarriesCommentsRunsAndEvents() throws {
        let idle: [String: JSONValue] = ["step_key": .null, "claim_lock": .null, "claim_expires": .null, "ended_at": .null,
                                         "outcome": .null, "summary": .null, "metadata": .null, "error": .null]
        func run(_ id: Double, _ fields: [String: JSONValue]) -> JSONValue {
            let common: [String: JSONValue] = ["id": .number(id), "task_id": "k-10", "profile": "career", "max_runtime_seconds": 3600]
            return .object(idle.merging(common) { $1 }.merging(fields) { $1 })
        }
        func event(_ id: Double, run runID: Double, _ kind: String, payload: JSONValue, at time: Double) -> JSONValue {
            ["id": .number(id), "task_id": "k-10", "run_id": .number(runID), "kind": .string(kind), "payload": payload, "created_at": .number(time)]
        }
        let task: JSONValue = [
            "id": "k-10", "title": "Sweep temp files", "body": "Under /tmp", "assignee": "career", "status": "review", "priority": 0,
            "created_by": "agent", "created_at": 1759990000, "started_at": 1760001000, "completed_at": .null, "workspace_kind": "scratch",
            "workspace_path": .null, "claim_lock": .null, "claim_expires": .null, "tenant": .null, "current_run_id": 13,
            "latest_summary": "12 files removed, 900 MB freed", "current_run_started_at": .null,
        ]
        let payload: JSONValue = [
            "task": task,
            "comments": [["id": 5, "task_id": "k-10", "author": "corey", "body": "Leave today's files", "created_at": 1759991000]],
            "events": [event(70, run: 12, "status", payload: ["from": "ready", "to": "running"], at: 1760001000),
                       event(71, run: 13, "review_requested", payload: .null, at: 1760001500)],
            "attachments": [],
            "links": ["parents": [], "children": ["k-11"]],
            "link_tasks": [:],
            "child_results": [["id": "k-11", "title": "Child", "status": "done", "latest_summary": .null, "result": "fine"]],
            "runs": [run(12, ["status": "ended", "worker_pid": 5151, "last_heartbeat_at": 1760001200, "started_at": 1760001000,
                              "ended_at": 1760001300, "outcome": "crashed", "error": "worker exited 2"]),
                     run(13, ["status": "running", "claim_lock": "w3", "claim_expires": 1760100000, "worker_pid": 5152,
                              "last_heartbeat_at": 1760001500, "started_at": 1760001400, "metadata": ["n": 1]])],
        ]
        let detail = try decode(KanbanTaskDetail.self, from: payload)
        #expect(detail.task.column == .review)
        #expect(detail.comments.map(\.author) == ["corey"])
        #expect(detail.runs.map(\.stateText).first == "crashed" && detail.runs.first?.durationSeconds == 300)
        #expect(detail.runs.map(\.isOpen) == [false, true])
        #expect(detail.currentRun?.id == 13)
        #expect(detail.events.map(\.line) == ["Moved to Running", "Review requested"])
        #expect(detail.links?.children == ["k-11"] && detail.childResults?.map(\.result) == ["fine"])
    }

    @Test func theBoardListDecodesAndNamelessBoardsUseTheirSlug() throws {
        let full: JSONValue = ["slug": "default", "name": "Default", "description": "", "icon": "", "color": "", "default_workdir": .null,
                               "project_id": .null, "created_at": .null, "archived": false, "is_current": true,
                               "counts": ["todo": 3, "running": 2, "archived": 1], "total": 5,
                               "default_workspace_kind": "scratch", "project_name": .null]
        let bare: JSONValue = ["slug": "garage", "name": "", "is_current": false, "counts": [:], "total": 0, "archived": false]
        let boards = try decode(KanbanBoards.self, from: ["boards": [full, bare], "current": "default"])
        #expect(boards.current == "default")
        #expect(boards.boards.map(\.displayName) == ["Default", "garage"])
        #expect(boards.boards.map(\.total) == [5, 0])
    }

    @Test func workersLogsEnvelopesAndEventFramesDecode() throws {
        var workerFields: [String: JSONValue] = ["run_id": 13, "task_id": "k-10", "profile": "career"]
        workerFields["task_title"] = "Sweep temp files"
        workerFields["task_status"] = "running"
        workerFields["task_assignee"] = "career"
        workerFields["worker_pid"] = 5152
        workerFields["started_at"] = 1760001400
        workerFields["claim_lock"] = "w3"
        workerFields["claim_expires"] = 1760100000
        workerFields["last_heartbeat_at"] = 1760001500
        workerFields["max_runtime_seconds"] = 3600
        let worker = JSONValue.object(workerFields)
        let workers = try decode(KanbanWorkers.self, from: ["workers": [worker], "count": 1, "checked_at": 1760001600])
        #expect(workers.workers.map { [String($0.id), $0.taskId] } == [["13", "k-10"]])

        let logBody: JSONValue = [
            "truncated": false, "content": "one\ntwo", "size_bytes": 9,
            "path": "/log", "task_id": "k-10", "exists": true,
        ]
        let log = try decode(KanbanLog.self, from: logBody)
        #expect(log.exists && log.content.hasSuffix("two"))

        let fresh: JSONValue = ["title": "Fresh", "id": "k-30", "assignee": "default", "status": "ready", "created_at": 1]
        let warning = "No gateway is running for this profile; the task will wait in 'ready'."
        let envelope = try decode(KanbanTaskEnvelope.self, from: ["task": fresh, "warning": .string(warning)])
        #expect(envelope.task?.id == "k-30" && envelope.warning?.hasPrefix("No gateway") == true)

        let said: JSONValue = ["id": 78, "task_id": "k-10", "run_id": .null, "kind": "commented", "payload": ["author": "corey"], "created_at": 1760001700]
        let page: JSONValue = ["cursor": 78, "events": [said]]
        let frame = try decode(KanbanEventsFrame.self, from: page)
        let lines = frame.events.map(\.line)
        #expect(frame.cursor == 78 && lines == ["Comment"])
    }
}

/// Which changes the app allows on a card, and which field names go over the wire.
@Suite struct KanbanMovesAndPatchesTests {
    @Test func onlyColumnsAPersonCanDropOntoAreTargets() {
        #expect(KanbanStatus.moveTargets == [.triage, .todo, .ready, .blocked, .done, .archived])
        for fixed in [KanbanStatus.running, .scheduled, .review] { #expect(!fixed.isMoveTarget) }
        #expect(KanbanStatus.running.notMovableReason?.contains("dispatcher") == true)
        #expect(KanbanStatus.done.asksForSummary)
        #expect(KanbanStatus.archived.asksToConfirm && KanbanStatus.blocked.asksToConfirm)
        #expect(!KanbanStatus.todo.asksToConfirm)
        #expect(KanbanStatus.columns.map(\.rawValue) == ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"])
    }

    @Test func aPatchSendsTheServersOwnFieldNames() {
        let patch = KanbanTaskPatch(status: .done, assignee: .some(nil), priority: 2, result: "Freed 900 MB", summary: "Freed 900 MB", blockReason: "needs a key")
        guard case .object(let sent) = patch.json else { Issue.record("a patch is an object"); return }
        #expect(sent["status"] == .string("done"))
        #expect(sent["assignee"] == .null, "clearing the assignee is sent as null")
        #expect(sent["priority"] == .number(2))
        #expect(sent["result"] == .string("Freed 900 MB"))
        #expect(sent["block_reason"] == .string("needs a key"))
        #expect(sent["title"] == nil, "what was not set is not sent")
    }

    @Test func aNewTaskLeavesOutAnEmptyBodyAndAlwaysSendsParents() {
        let task = KanbanNewTask(title: "Water the plants", body: "", assignee: "career", priority: 1, triage: true)
        guard case .object(let sent) = task.json else { Issue.record("a new task is an object"); return }
        #expect(sent["title"] == .string("Water the plants"))
        #expect(sent["body"] == nil)
        #expect(sent["assignee"] == .string("career"))
        #expect(sent["triage"] == .bool(true))
        #expect(sent["parents"] == .array([]))
    }

    @Test func theEventCursorStartsAtTheBoardAndOnlyMovesForward() {
        var cursor = KanbanEventCursor()
        #expect(cursor.sinceQuery == nil)
        cursor.start(fromBoard: 77)
        #expect(cursor.cursor == 77 && cursor.sinceQuery?.value == "77")
        cursor.start(fromBoard: 5)
        #expect(cursor.cursor == 77, "a later board read never moves it back")

        let event = KanbanEvent(id: 78, taskId: "k-10", runId: nil, kind: "commented", payload: nil, createdAt: 1)
        let fresh = cursor.take(KanbanEventsFrame(events: [event], cursor: 78))
        #expect(fresh && cursor.cursor == 78)
        let empty = cursor.take(KanbanEventsFrame(events: [], cursor: 78))
        #expect(!empty, "nothing new")
        let behind = cursor.take(KanbanEventsFrame(events: [event], cursor: 60))
        #expect(behind && cursor.cursor == 78, "events count, an older cursor does not rewind")
    }
}
