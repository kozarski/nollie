import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// When a queued message can't be sent, what happens to the ones behind it depends on why. A refusal
/// is about that message alone, so the next one goes. A dropped line would fail them all, so they wait
/// and go once the chat is back.

/// The gateway for one chat: records each prompt and fails the next ones as told.
@MainActor private final class Line {
    private(set) var prompts: [String] = []
    var failures: [any Error] = []

    func answer(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "prompt.submit":
            prompts.append(params["text"]?.stringValue ?? "")
            if !failures.isEmpty { throw failures.removeFirst() }
            return ["status": "ok"]
        case "session.resume":
            return ["session_id": "live-1", "running": false, "messages": []]
        default:
            return ["status": "ok"]
        }
    }
}

@MainActor @Suite struct SendQueueFailureTests {
    private func bench() throws -> (chat: ChatSession, line: Line) {
        let chat = try ChatFixtures.chat(stored: "stored-queue")
        chat.runtimeID = "live-1"
        let line = Line()
        chat.gatewayStandIn = { method, params in try await line.answer(method, params) }
        return (chat, line)
    }

    private func pump(_ ready: () -> Bool) async {
        var turns = 0
        while !ready() && turns < 1000 {
            await Task.yield()
            turns += 1
        }
    }

    private func finishTurn(_ chat: ChatSession) {
        chat.handle(event: ChatFixtures.event(for: chat, "message.complete", ["text": "Done.", "status": "complete"]))
    }

    private func failures(_ chat: ChatSession) -> Int {
        chat.items.filter { if case .error = $0.kind { true } else { false } }.count
    }

    /// Three messages: the first runs, the other two wait behind it.
    private func queueTwo(_ chat: ChatSession) async throws {
        await chat.send("first")
        try #require(chat.isRunning)
        await chat.send("second")
        await chat.send("third")
        try #require(chat.queue.map(\.text) == ["second", "third"])
    }

    @Test func aDroppedLineKeepsTheRestQueuedUntilTheChatIsBack() async throws {
        let (chat, line) = try bench()
        try await queueTwo(chat)
        line.failures = [SocketError.closed(code: 1006, reason: "")]
        finishTurn(chat)
        await pump { failures(chat) == 1 && !chat.isSubmitting }
        #expect(line.prompts == ["first", "second"])
        #expect(chat.queue.map(\.text) == ["third"], "the next one is not sent into a dropped line")
        #expect(!chat.isRunning)
        #expect(failures(chat) == 1, "one failure, not one for every queued message")

        await chat.reattachAfterReconnect()
        await pump { line.prompts.count == 3 }
        #expect(line.prompts == ["first", "second", "third"])
        #expect(chat.queue.isEmpty)
    }

    @Test func aTimeoutAlsoKeepsTheRestQueued() async throws {
        let (chat, line) = try bench()
        try await queueTwo(chat)
        line.failures = [SocketError.timeout("prompt.submit")]
        finishTurn(chat)
        await pump { failures(chat) == 1 && !chat.isSubmitting }
        #expect(line.prompts == ["first", "second"], "the uncertain message is not sent again")
        #expect(chat.queue.map(\.text) == ["third"])
    }

    @Test func aRefusedMessageLetsTheNextOneGo() async throws {
        let (chat, line) = try bench()
        try await queueTwo(chat)
        line.failures = [RPCError(code: -32000, message: "That message was too long.")]
        finishTurn(chat)
        await pump { line.prompts.count == 3 }
        #expect(line.prompts == ["first", "second", "third"])
        #expect(chat.queue.isEmpty)
        #expect(failures(chat) == 1)
        #expect(chat.isRunning, "the third message is running")
    }
}
