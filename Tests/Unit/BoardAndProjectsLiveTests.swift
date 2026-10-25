import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Board and the projects against the mock gateway, which they are free to change.
extension LiveGatewayTests {
    @Suite struct Board {
        /// Probing detects the plugin and saves the result for the next launch. Switching boards
        /// loads the new one (and saves that too). Several events arriving together over the
        /// plugin socket trigger a single board read, never one per event.
        @MainActor @Test func probeSelectionAndTheLiveSocketBehaveAsTheBoardExpects() async throws {
            guard let target = LiveGatewayTests.mockTarget else { return }
            let store = ConnectionStore()
            let (connection, runtime) = try LiveGatewayTests.connect(target, named: "live board store", store: store)
            defer { store.delete(id: connection.id) }
            await runtime.start()
            defer { Task { await runtime.stop() } }
            let board = runtime.kanban
            let defaults = UserDefaults.standard

            // The plugin responds, both boards are listed along with the current one, and the result
            // is stored per gateway so the page stays steady on the next launch.
            await board.probe()
            #expect(board.availability == .present && board.isPresent)
            #expect(board.boards.map(\.slug).sorted() == ["default", "homelab"], "the mock has two boards")
            #expect(board.selectedBoard == "default", "nothing chosen here, so the gateway's current board")
            #expect(defaults.string(forKey: "kanban.available." + connection.id.uuidString) == "present")
            await board.refresh()
            let firstBoard = try #require(board.board)
            let firstCards = firstBoard.columns.flatMap(\.tasks).map(\.id)

            // Bring another board forward: it gets its own read and is remembered for this gateway.
            board.select(board: "homelab")
            #expect(board.selectedBoard == "homelab" && board.board == nil)
            for _ in 0..<50 where board.board == nil { try await Task.sleep(for: .milliseconds(100)) }
            let secondBoard = try #require(board.board, "the other board was read")
            var secondCards: [String] = []
            for column in secondBoard.columns { secondCards += column.tasks.map(\.id) }
            #expect(!secondCards.isEmpty, "the second board has no cards")
            #expect(secondCards != firstCards, "cards of a different board")
            #expect(defaults.string(forKey: "kanban.board." + connection.id.uuidString) == "homelab")
            #expect(board.selectedBoardMeta?.name == "Homelab")

            // Picking a board also connects the plugin socket for it.
            for _ in 0..<50 where !board.liveConnected { try await Task.sleep(for: .milliseconds(100)) }
            #expect(board.liveConnected, "the events socket is up")

            // Three edits go directly to the gateway, bypassing the store (which re-reads after its
            // own writes). Their events arrive together in one socket frame (the mock polls every
            // second), so the store reads once for all three, or twice if the writes fell across a
            // tick, but never three times.
            let api = try #require(board.api)
            let firstCard = try #require(secondBoard.columns.flatMap(\.tasks).first)
            let readsBefore = board.reads
            for n in 1...3 { try await api.comment(firstCard.id, "batched \(n)") }
            for _ in 0..<100 where board.reads == readsBefore { try await Task.sleep(for: .milliseconds(100)) }
            #expect(board.reads > readsBefore, "the store never re-read the board after the events")
            try await Task.sleep(for: .seconds(1.5))   // and no further reads for those events
            let extra = board.reads - readsBefore
            #expect(extra <= 2, "simultaneous events should share a read (\(extra) extra)")

            board.stopEvents()
            #expect(!board.liveConnected)
        }

        /// When the server rejects a change, its message stays on screen through the next board read.
        /// That read used to clear it, so a rejected move seemed to do nothing.
        @MainActor @Test func aRefusedMoveKeepsTheServersWordsAfterTheNextRead() async throws {
            guard let target = LiveGatewayTests.mockTarget else { return }
            let store = ConnectionStore()
            let (connection, runtime) = try LiveGatewayTests.connect(target, named: "live board refusal", store: store)
            defer { store.delete(id: connection.id) }
            await runtime.start()
            defer { Task { await runtime.stop() } }
            let board = runtime.kanban
            await board.probe()
            await board.refresh()
            let card = try #require(board.board?.tasks(in: .ready).first, "no Ready task on the mock board")

            // Finishing a task with no summary makes the mock answer 409 with a reason, like the server.
            let moved = await board.move(card, to: .done)
            #expect(!moved)
            #expect(board.lastError?.contains("marked done") == true, "the refusal should reach the screen: \(board.lastError ?? "nil")")
            #expect(board.lastRefusal == board.lastError)
            #expect(board.board?.task(id: card.id)?.column == .ready, "the card stays where it was")
            // A later successful write wipes the message.
            #expect(await board.setPriority(card, card.priority ?? 0))
            #expect(board.lastRefusal == nil && board.lastError == nil)
        }
    }

    @Suite struct Projects {
        /// Put a stored chat into a project and then out again, checking the gateway's tree each
        /// time. The first chat must be movable, which holds for the mock.
        @MainActor @Test func aChatMovesIntoAProjectAndBackOut() async throws {
            guard let target = LiveGatewayTests.mockTarget else { return }
            let store = ConnectionStore()
            let (connection, runtime) = try LiveGatewayTests.connect(target, named: "live projects", store: store)
            defer { store.delete(id: connection.id) }
            await runtime.start()
            await runtime.projects.refresh()
            try #require(runtime.projects.available == true)
            let project = try #require(runtime.projects.open.first)
            let fiveChats = [URLQueryItem(name: "limit", value: "5")]
            let page: SessionListResponse = try await runtime.api.get("/api/sessions", query: fiveChats, profile: runtime.selectedProfile)
            let chat = try #require(page.sessions.first { runtime.projects.membership[$0.id] != project.id })
            let originalProject = runtime.projects.project(forSession: chat.id)

            try await runtime.projects.move([chat.id], to: project)
            #expect(runtime.projects.membership[chat.id] == project.id)
            await runtime.projects.refreshTree()
            #expect(runtime.projects.membership[chat.id] == project.id, "the gateway tree does not list the chat under the project")

            try await runtime.projects.move([chat.id], to: nil)
            let afterRemoval = runtime.projects.membership[chat.id]
            #expect(afterRemoval == nil)

            // Moving into a folder that does not exist brings back the gateway's message and leaves the chat alone.
            var ghost = project
            ghost.primaryPath = "/nowhere/at/all"
            await #expect(throws: (any Error).self) { try await runtime.projects.move([chat.id], to: ghost) }
            #expect(runtime.projects.membership[chat.id] == nil)

            if let originalProject { try await runtime.projects.move([chat.id], to: originalProject) }
            await runtime.stop()
        }
    }
}
