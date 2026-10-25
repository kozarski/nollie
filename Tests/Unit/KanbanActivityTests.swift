import Foundation
import Testing
@testable import NollieCore

@Suite struct KanbanActivityTests {
    /// These checks keep the bots marked Private (here "private" and "Moss") out of Board activity.
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    private let now = Date(timeIntervalSince1970: 20_000)

    private func worker(assignee: String? = "forager", dispatcher: String? = "default", status: String = "running", pid: Int = 42) throws -> KanbanWorker {
        var row: [String: Any] = ["run_id": 1, "task_id": "fixture-task", "task_status": status, "worker_pid": pid]
        row["task_assignee"] = assignee
        row["profile"] = dispatcher
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(KanbanWorker.self, from: JSONSerialization.data(withJSONObject: row))
    }

    @Test func taskAssigneeWinsOverTheDispatcherProfile() throws {
        #expect(KanbanActivity.owner(of: try worker()) == "forager")
        #expect(KanbanActivity.owner(of: try worker(assignee: nil)) == "default")
        #expect(KanbanActivity.owner(of: try worker(assignee: "", dispatcher: nil)) == nil)
    }

    @Test func everyBoardContributesWithoutReadingTaskOrConversationBodies() async throws {
        let forager = try worker()
        let scout = try worker(assignee: "career")
        let snapshot = await KanbanActivity.read(boards: ["default", "projects", "default"], profiles: ["default", "forager", "career"], now: now) { board in
            board == "default" ? [forager] : [scout]
        }
        #expect(snapshot.state(for: "forager", now: now) == .working)
        #expect(snapshot.state(for: "career", now: now) == .working)
        #expect(snapshot.state(for: "default", now: now) == .idle)
    }

    @Test func failedReadsDoNotReportIdleOrKeepEarlierWorkersRunning() async throws {
        let forager = try worker()
        let partial = await KanbanActivity.read(boards: ["default", "projects"], profiles: ["default", "forager"], now: now) { board in
            if board == "projects" { throw URLError(.timedOut) }
            return [forager]
        }
        #expect(partial.state(for: "forager", now: now) == .working)
        #expect(partial.state(for: "default", now: now) == .unknown)
        let failed = await KanbanActivity.read(boards: ["default"], profiles: ["forager"], now: now) { _ in throw URLError(.notConnectedToInternet) }
        #expect(failed.state(for: "forager", now: now) == .unknown)
    }

    @Test func aFinishedWorkerClearsAndStaleEvidenceBecomesUnknown() async throws {
        let done = try worker(status: "done")
        let missingPID = try worker(pid: 0)
        let snapshot = await KanbanActivity.read(boards: ["default"], profiles: ["forager"], now: now) { _ in [done, missingPID] }
        #expect(snapshot.state(for: "forager", now: now) == .idle)
        #expect(snapshot.state(for: "forager", now: now.addingTimeInterval(45)) == .unknown)
        #expect(snapshot.state(for: "forager", now: now.addingTimeInterval(-6)) == .unknown)
    }

    @Test func privateAndUnrecognizedProfilesAreExcluded() async throws {
        let hidden = try worker(assignee: "private")
        let missing = try worker(assignee: "unknown")
        let snapshot = await KanbanActivity.read(boards: ["default", "private"], profiles: ["forager", "private"], now: now) { board in
            #expect(board != "private")
            return [hidden, missing]
        }
        #expect(snapshot.activeProfiles.isEmpty)
    }

    @Test func cancellationCannotPublishAWorkerThatReturnedLate() async throws {
        let worker = try worker()
        let task = Task {
            await KanbanActivity.read(boards: ["default"], profiles: ["forager"], now: now) { _ in
                try? await Task.sleep(for: .seconds(30))
                return [worker]
            }
        }
        task.cancel()
        let snapshot = await task.value
        #expect(snapshot.state(for: "forager", now: now) == .unknown)
    }
}
