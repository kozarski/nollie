import Foundation
import Testing
@testable import Nollie
import NollieCore

@Suite struct BoardChatContextTests {
    private func task(status: String = "blocked") -> KanbanTask {
        var task = KanbanTask(id: "task-1", title: "Choose the export format", status: status,
                              body: "Choose CSV or JSON.\nThe existing export is unchanged.", assignee: "worker")
        task.sessionId = "origin-chat"
        return task
    }

    @Test func contextKeepsTheTaskAndItsOriginWithoutAssumingTheAssigneeOwnsTheChat() throws {
        let connection = UUID()
        let source = task()
        let context = try #require(BoardChatContext(task: source, connectionID: connection, board: "work", boardName: "Work"))
        #expect(context.taskID == source.id)
        #expect(context.title == source.title)
        #expect(context.status == "blocked")
        #expect(context.statusTitle == "Blocked")
        #expect(context.board == "work")
        #expect(context.boardName == "Work")
        #expect(context.reason == "Choose CSV or JSON.")
        let route = context.route
        #expect(route.connectionID == connection)
        #expect(route.storedSessionID == "origin-chat")
        #expect(route.profile == nil)
        #expect(route.replyText == nil)
        #expect(route.action == nil)
        #expect(route.requestID == nil)
        #expect(route.token != context.route.token)
        #expect(source.status == "blocked")
    }

    @Test func blockedContextExplainsTheFailureBeforeTheGeneralSummary() throws {
        var source = task()
        source.lastFailureError = "  The export folder needs a location.\nInternal follow-up details."
        source.latestSummary = "The export is ready to configure."
        let context = try #require(BoardChatContext(task: source, connectionID: UUID(), board: nil, boardName: nil))
        #expect(context.reason == "The export folder needs a location.")
        #expect(context.boardName == "Board")
    }

    @Test func reviewUsesTheCurrentHandoffAndKeepsTheReasonShort() throws {
        var source = task(status: "review")
        source.lastFailureError = "An older attempt failed."
        source.latestSummary = "\n  " + String(repeating: "x", count: 300) + "\nMore information."
        let context = try #require(BoardChatContext(task: source, connectionID: UUID(), board: nil, boardName: ""))
        #expect(context.reason == String(repeating: "x", count: 239) + "…")
        #expect(context.reason?.count == 240)
        #expect(context.statusTitle == "Review")
    }

    @Test func contextOnlyAppearsForItsGatewayAndChat() throws {
        let connection = UUID()
        let context = try #require(BoardChatContext(task: task(), connectionID: connection, board: nil, boardName: nil))
        #expect(context.matches(connectionID: connection, sessionID: "origin-chat"))
        #expect(!context.matches(connectionID: UUID(), sessionID: "origin-chat"))
        #expect(!context.matches(connectionID: connection, sessionID: "other-chat"))
    }

    @Test func missingChatCannotCreateAContextAndEmptyReasonsStayEmpty() throws {
        var source = task()
        for session in [nil, "", " \n "] as [String?] {
            source.sessionId = session
            #expect(BoardChatContext(task: source, connectionID: UUID(), board: nil, boardName: nil) == nil)
        }
        source.sessionId = "origin-chat"
        source.body = " \n "
        let context = try #require(BoardChatContext(task: source, connectionID: UUID(), board: nil, boardName: nil))
        #expect(context.reason == nil)
    }
}
