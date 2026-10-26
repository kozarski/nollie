import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// A gateway the app lets go of takes its chats with it: nothing stays alive through the loop between
/// the runtime and its open chats, and nothing is left waiting for an answer that cannot come.
@MainActor @Suite struct RuntimeDisposalTests {
    private func pump(_ ready: () -> Bool) async {
        var turns = 0
        while !ready() && turns < 1000 {
            await Task.yield()
            turns += 1
        }
    }

    private func approval() -> ServerRequest {
        ServerRequest(id: "rq-1", method: "approval", params: .object([
            "session_id": "live-1", "request_id": "ap-1", "command": "git clean -fd build",
        ]))
    }

    @Test func aDisposedRuntimeAndItsChatsAreFreed() async throws {
        weak var runtime: GatewayRuntime?
        weak var chat: ChatSession?
        do {
            let held = try ChatFixtures.runtime(named: "dispose-free")
            held.socketEnabled = false
            let opened = ChatSession(runtime: held, storedID: "stored-1", title: nil)
            held.registry.add(opened)
            runtime = held
            chat = opened
            try #require(held.chats.count == 1)
            await held.dispose()
            #expect(held.chats.isEmpty)
        }
        await pump { runtime == nil && chat == nil }
        #expect(chat == nil, "the chat is gone with its runtime")
        #expect(runtime == nil, "the runtime, and the transcripts and sign-in it held, are gone")
    }

    @Test func aChatAScreenStillHoldsOutlivesTheDisposalButNotTheScreen() async throws {
        weak var runtime: GatewayRuntime?
        var screen: ChatSession?
        do {
            let held = try ChatFixtures.runtime(named: "dispose-screen")
            held.socketEnabled = false
            let opened = ChatSession(runtime: held, storedID: "stored-2", title: nil)
            held.registry.add(opened)
            opened.items = [TestRows.user("u1", "Hello")]
            runtime = held
            screen = opened
            await held.dispose()
        }
        #expect(screen?.items.count == 1, "still readable")
        #expect(runtime != nil && runtime?.chats.isEmpty == true)
        screen = nil
        await pump { runtime == nil }
        #expect(runtime == nil)
    }

    @Test func aWaitingApprovalIsLetGoWithNoDecision() async throws {
        let held = try ChatFixtures.runtime(named: "dispose-approval")
        held.socketEnabled = false
        let chat = ChatSession(runtime: held, storedID: "stored-3", title: nil)
        chat.runtimeID = "live-1"
        held.registry.add(chat)
        let request = approval()
        var answered = false
        var answer: JSONValue?
        let waiting = Task {
            answer = await chat.answer(serverRequest: request)
            answered = true
        }
        await pump { !chat.cards.isEmpty }
        try #require(chat.cards.count == 1)
        #expect(!answered)

        await held.dispose()
        await pump { answered }
        await waiting.value
        #expect(answered, "nothing is left hanging")
        #expect(answer == nil, "and no decision is sent for the person")
    }

    @Test func aDisposedRuntimeOpensNoMoreChatsAndDoesNotStartAgain() async throws {
        let held = try ChatFixtures.runtime(named: "dispose-closed")
        held.socketEnabled = false
        await held.dispose()
        #expect(held.isDisposed)
        await #expect(throws: (any Error).self) { try await held.openChat(storedID: "stored-4", profile: "default") }
        await #expect(throws: (any Error).self) { try await held.newChat() }
        await held.start()
        #expect(held.chats.isEmpty)
    }

    @Test func aChatStillOnScreenStopsLookingBusy() async throws {
        let held = try ChatFixtures.runtime(named: "dispose-typing")
        held.socketEnabled = false
        let chat = ChatSession(runtime: held, storedID: "stored-6", title: nil)
        chat.runtimeID = "live-6"
        chat.gatewayStandIn = { _, _ in ["status": "ok"] }
        held.registry.add(chat)
        await chat.send("Hello")
        chat.handle(event: ChatFixtures.event(for: chat, "message.delta", ["text": "Half a rep"]))
        try #require(chat.isRunning && chat.statusLine != nil)
        try #require(chat.items.contains { if case .assistant(_, _, true) = $0.kind { true } else { false } })

        await held.dispose()
        #expect(!chat.isRunning, "no typing dots for an answer that can't come")
        #expect(chat.statusLine == nil)
        #expect(!chat.isSubmitting)
        #expect(!chat.items.contains { if case .assistant(_, _, true) = $0.kind { true } else { false } },
                "what the bot had said stands as a finished bubble")
        #expect(chat.items.contains { if case .assistant("Half a rep", _, false) = $0.kind { true } else { false } })
    }

    @Test func stoppingAloneKeepsTheChatsForARestart() async throws {
        let held = try ChatFixtures.runtime(named: "dispose-stop")
        held.socketEnabled = false
        let chat = ChatSession(runtime: held, storedID: "stored-5", title: nil)
        held.registry.add(chat)
        await held.stop()
        #expect(held.chats.count == 1 && !held.isDisposed)
    }
}
