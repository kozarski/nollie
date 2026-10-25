import Testing
@testable import Nollie
import NollieCore

@Suite struct KanbanPresentationGroupTests {
    private func board(_ tasks: [KanbanTask]) -> KanbanBoard {
        KanbanBoard(columns: [.init(name: "fixture", tasks: tasks)])
    }

    @Test func everyVisibleGatewayStatusAppearsOnceAndKeepsItsMeaning() {
        let tasks = KanbanStatus.allCases.map { KanbanTask(id: $0.rawValue, title: $0.title, status: $0.rawValue) }
        let source = board(tasks)
        let groups = KanbanPresentationGroup.allCases
        #expect(groups.map(\.title) == ["Pending", "Blocked", "Done"])
        let presented = groups.flatMap { $0.tasks(in: source) }
        #expect(Set(presented.map(\.id)) == Set(KanbanStatus.columns.map(\.rawValue)))
        #expect(presented.count == KanbanStatus.columns.count)
        #expect(source.allTasks == tasks)
        #expect(KanbanPresentationGroup.blocked.tasks(in: source).map(\.status) == ["blocked"])
        #expect(KanbanPresentationGroup.group(for: .archived) == nil)
    }

    @Test func pendingPutsCurrentWorkFirstAndKeepsGatewayOrderWithinEachStage() {
        let source = board([
            .init(id: "scheduled", title: "Later", status: "scheduled"),
            .init(id: "ready-b", title: "Second", status: "ready"),
            .init(id: "triage", title: "Plan", status: "triage"),
            .init(id: "ready-a", title: "First", status: "ready"),
            .init(id: "todo", title: "Next", status: "todo"),
            .init(id: "running", title: "Working", status: "running"),
        ])
        #expect(KanbanPresentationGroup.pending.tasks(in: source).map(\.id) == ["running", "ready-b", "ready-a", "todo", "triage", "scheduled"])
    }

    @Test func blockedKeepsEveryTaskAvailableWithoutChangingItsStatus() {
        let tasks = (1...31).map { KanbanTask(id: "waiting-\($0)", title: "Waiting \($0)", status: "blocked") }
        let source = board(tasks)
        #expect(KanbanPresentationGroup.blocked.tasks(in: source) == tasks)
        #expect(source.allTasks.allSatisfy { $0.status == "blocked" })
    }

    @Test func doneAndReviewRemainAvailableInDifferentLanes() {
        let source = board([
            .init(id: "done", title: "Finished", status: "done"),
            .init(id: "review", title: "Check", status: "review"),
        ])
        #expect(KanbanPresentationGroup.done.tasks(in: source).map(\.id) == ["done"])
        #expect(KanbanPresentationGroup.pending.tasks(in: source).map(\.id) == ["review"])
    }

    @Test func duplicateReviewsDoNotInflateTheSectionAndUnknownStatusesRemainAvailable() {
        let review = KanbanTask(id: "review", title: "Check", status: "review")
        let unknown = KanbanTask(id: "unknown", title: "New status", status: "waiting_for_input")
        let source = board([review, review, unknown, .init(id: "archived", title: "Old", status: "archived")])
        #expect(KanbanPresentationGroup.blocked.tasks(in: source).isEmpty)
        #expect(KanbanPresentationGroup.pending.tasks(in: source) == [review, unknown])
        let count = BoardReviewSummary(boards: [], selectedBoard: "fixture", loadedBoard: source).count
        #expect(count == KanbanPresentationGroup.blocked.tasks(in: source).count)
    }

    @Test func droppingIntoPendingReturnsTheTaskToTheQueue() {
        #expect(KanbanPresentationGroup.pending.moveTarget == .todo)
        #expect(KanbanPresentationGroup.blocked.moveTarget == .blocked)
        #expect(KanbanPresentationGroup.done.moveTarget == .done)
        #expect(KanbanPresentationGroup.allCases.allSatisfy { $0.moveTarget.isMoveTarget })
    }

    @Test func recoveryAndDependencyWaitsStayPendingButQuestionsStayBlocked() {
        for kind in ["transient", "dependency", "needs_input", "capability"] {
            var task = KanbanTask(id: kind, title: "Waiting", status: "blocked")
            task.blockKind = kind
            let expected: KanbanPresentationGroup = ["transient", "dependency"].contains(kind) ? .pending : .blocked
            #expect(KanbanPresentationGroup.group(for: task) == expected)
            #expect(expected.tasks(in: board([task])) == [task])
            #expect(task.status == "blocked")
        }
    }
}
