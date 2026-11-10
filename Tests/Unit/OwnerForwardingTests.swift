import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

// Hermes 0.23 hands a prompt to the chat's owner when the gateway is running a turn there: a quiet wait, then
// the history read again for the whole reply. Or the owner turns it away with a reason, said plainly.

/// One chat's gateway: answers prompt.submit as told and serves a history for session.resume.
@MainActor private final class OwnerLine {
    var submit: Result<JSONValue, RPCError> = .success(["status": "streaming"])
    var history: [JSONValue] = []
    private(set) var prompts: [String] = []
    private(set) var resumes = 0

    func answer(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "prompt.submit":
            prompts.append(params["text"]?.stringValue ?? "")
            return try submit.get()
        case "session.resume":
            resumes += 1
            return ["session_id": "live-owner", "stored_session_id": "stored-owner", "running": false, "messages": .array(history)]
        default:
            return ["status": "ok"]
        }
    }
}

private func ownerRefusal(_ reason: String, _ message: String = "refused") -> RPCError {
    RPCError(code: 4090, message: message, data: ["reason": .string(reason)])
}

@MainActor @Suite struct OwnerForwardingTests {
    private func bench() throws -> (chat: ChatSession, line: OwnerLine) {
        let chat = try ChatFixtures.chat(stored: "stored-owner")
        chat.runtimeID = "live-owner"
        let line = OwnerLine()
        chat.gatewayStandIn = { method, params in try await line.answer(method, params) }
        return (chat, line)
    }

    private func pump(_ ready: () -> Bool) async {
        var turns = 0
        while !ready() && turns < 2000 {
            await Task.yield()
            turns += 1
        }
    }

    private func errors(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .error(let text) = $0.kind { text } else { nil } }
    }

    private func replies(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .assistant(let text, _, _) = $0.kind { text } else { nil } }
    }

    @Test func aForwardedPromptWaitsQuietlyThenTheHistoryBringsTheReply() async throws {
        let (chat, line) = try bench()
        line.submit = .success(["status": "queued", "admission_id": "adm-1", "forwarded": true])
        await chat.send("Move the export to 2 AM")
        #expect(chat.isRunning)
        #expect(chat.statusLine == ChatSession.waitingForOtherChatLine)
        #expect(ChatSession.statusWords(ChatSession.waitingForOtherChatLine).isEmpty == false)

        // Only the start and an empty complete come back for it.
        chat.handle(event: ChatFixtures.event(for: chat, "message.start", ["turn_id": "owner-turn"]))
        line.history = [
            ["role": "user", "text": "Move the export to 2 AM", "timestamp": 1_800_000_000, "row_id": 1],
            ["role": "assistant", "text": "Done. It runs at 2 AM now.", "timestamp": 1_800_000_010, "row_id": 2],
        ]
        chat.handle(event: ChatFixtures.event(for: chat, "message.complete", ["text": "", "turn_id": "owner-turn"]))
        await pump { line.resumes > 0 && replies(chat).contains("Done. It runs at 2 AM now.") }
        #expect(line.resumes == 1)
        #expect(!chat.isRunning)
        #expect(replies(chat).last == "Done. It runs at 2 AM now.")
    }

    @Test func anOrdinaryQueuedAnswerIsNotTakenForAForward() async throws {
        let (chat, line) = try bench()
        line.submit = .success(["status": "queued"])
        await chat.send("Hello")
        #expect(chat.statusLine == "Queued on the gateway")
        chat.handle(event: ChatFixtures.event(for: chat, "message.complete", ["text": "Hi.", "status": "complete"]))
        await Task.yield()
        #expect(line.resumes == 0)
    }

    @Test func aBusyOwnerOffersTryAgainWhichSendsOnce() async throws {
        let (chat, line) = try bench()
        line.submit = .failure(ownerRefusal("SESSION_OWNER_BUSY"))
        await chat.send("Draft the note")
        #expect(!chat.isRunning)
        #expect(errors(chat) == [OwnerRefusal.busy.words])
        let row = try #require(chat.items.last?.id)
        #expect(chat.retryableFailures == [row])

        line.submit = .success(["status": "streaming"])
        await chat.sendAgain(failure: row)
        #expect(line.prompts == ["Draft the note", "Draft the note"])
        #expect(errors(chat).isEmpty)
        #expect(chat.retryableFailures.isEmpty)
        let bubbles = chat.items.filter { if case .user = $0.kind { true } else { false } }
        #expect(bubbles.count == 1, "the old bubble gives way to the new send")
        await chat.sendAgain(failure: row)
        #expect(line.prompts.count == 2)
    }

    @Test func anUnconfirmedMessageIsSaidButNeverOfferedAgain() async throws {
        let (chat, line) = try bench()
        line.submit = .failure(ownerRefusal("SESSION_OWNER_UNCONFIRMED"))
        await chat.send("Pay the invoice")
        #expect(errors(chat) == [OwnerRefusal.unconfirmed.words])
        #expect(chat.retryableFailures.isEmpty)
        #expect(line.prompts == ["Pay the invoice"])
    }

    @Test func notOwnedHasItsOwnWordsAndOtherRefusalsKeepHermesWords() async throws {
        let (chat, line) = try bench()
        line.submit = .failure(ownerRefusal("SESSION_NOT_OWNED"))
        await chat.send("One")
        line.submit = .failure(RPCError(code: 4090, message: "session busy"))
        await chat.send("Two")
        #expect(errors(chat) == [OwnerRefusal.notOwned.words, "session busy"])
        #expect(chat.retryableFailures.isEmpty)
    }

    @Test func theRefusalReadsItsReasonOnly() {
        #expect(OwnerRefusal(code: 4090, reason: "SESSION_OWNER_BUSY") == .busy)
        #expect(OwnerRefusal(code: 4091, reason: "SESSION_OWNER_BUSY") == nil)
        #expect(OwnerRefusal(code: 4090, reason: nil) == nil)
        #expect(OwnerRefusal(code: 4090, reason: "SOMETHING_ELSE") == nil)
        #expect(OwnerRefusal.busy.offersRetry && !OwnerRefusal.unconfirmed.offersRetry && !OwnerRefusal.notOwned.offersRetry)
        #expect(OwnerRefusal.isForwarded(["status": "queued", "forwarded": true]))
        #expect(!OwnerRefusal.isForwarded(["status": "queued"]))
        for refusal in [OwnerRefusal.busy, .unconfirmed, .notOwned] { #expect(!refusal.words.contains("\u{2014}")) }
    }
}

@MainActor @Suite struct ToolProgressTests {
    private func feed(_ chat: ChatSession, _ type: String, _ fields: [String: JSONValue]) {
        chat.handle(event: ChatFixtures.event(for: chat, type, fields))
    }

    private func tool(_ chat: ChatSession) -> ToolActivity? {
        chat.items.lazy.compactMap { if case .tool(let step) = $0.kind { step } else { nil } }.last
    }

    @Test func aRunningStepShowsHowFarItHasGot() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start", [:])
        feed(chat, "tool.start", ["tool_id": "t1", "name": "read_pages"])
        feed(chat, "tool.progress", ["tool_id": "t1", "name": "read_pages", "progress": 3, "total": 10, "percent": 30])
        let step = try #require(tool(chat))
        #expect(step.progress?.fraction == 0.3)
        #expect(step.progress?.shortText.contains("3") == true && step.progress?.shortText.contains("10") == true)

        feed(chat, "tool.progress", ["tool_id": "other", "name": "x", "progress": 9])
        #expect(tool(chat)?.progress?.done == 3, "another tool's progress leaves this row alone")
        feed(chat, "tool.complete", ["tool_id": "t1", "name": "read_pages"])
        feed(chat, "tool.progress", ["tool_id": "t1", "name": "read_pages", "progress": 10, "total": 10])
        #expect(tool(chat)?.progress?.done == 3, "a finished step takes no more")
    }

    @Test func progressReadsWhatTheToolGives() {
        #expect(ToolProgress(progress: 4, total: nil, percent: 40, message: nil)?.fraction == 0.4)
        #expect(ToolProgress(progress: 4, total: nil, percent: nil, message: "")?.fraction == nil)
        #expect(ToolProgress(progress: 4, total: nil, percent: nil, message: "")?.message == nil)
        #expect(ToolProgress(progress: 12, total: 10, percent: nil, message: nil)?.fraction == 1)
        #expect(ToolProgress(progress: nil, total: 10, percent: nil, message: nil) == nil)
        #expect(ToolProgress(progress: -1, total: 10, percent: nil, message: nil) == nil)
        #expect(ToolProgress(progress: 2, total: 0, percent: nil, message: nil)?.total == nil)
    }

    @Test func theReducerKeepsProgressOnItsStep() {
        var state = ConversationReducer.reduce(ConversationState(lineage: ConversationLineage(tip: "s0")),
                                               .attached(ConversationSnapshot(runtimeSession: "rt-1", storedSession: "s0"),
                                                         held: [], requestedAt: 0, full: false))
        func event(_ type: String, _ seq: Int, _ payload: GatewayJSON) -> ConversationInput {
            .event(GatewayEventEnvelope(type: type, sessionId: "rt-1", seq: seq, payload: payload))
        }
        state = ConversationReducer.reduce(state, [
            event("message.start", 1, [:]),
            event("tool.start", 2, ["tool_id": "t1", "name": "read_pages"]),
            event("tool.progress", 3, ["tool_id": "t1", "name": "read_pages", "progress": 7, "total": 10]),
        ])
        let step = state.rows.compactMap { if case .tool(let step) = $0.kind { step } else { nil } }.last
        #expect(step?.progress?.done == 7)
    }
}

@Suite struct OwnerForwardingEngineTests {
    @Test func aForwardedSendWaitsForTheOtherChat() {
        var state = ConversationReducer.reduce(ConversationState(lineage: ConversationLineage(tip: "s0")),
                                               .attached(ConversationSnapshot(runtimeSession: "rt-1", storedSession: "s0"),
                                                         held: [], requestedAt: 0, full: false))
        state = ConversationReducer.reduce(state, .compose(text: "Move the export"))
        let id = state.outbox.entries.last!.id
        state = ConversationReducer.reduce(state, [.sendStarted(id: id), .sendFinished(id: id, .forwarded)])
        #expect(state.activity == .waitingForOtherChat)
        #expect(state.outbox[id]?.state == .sent)
        state = ConversationReducer.reduce(state, .event(GatewayEventEnvelope(type: "message.start", sessionId: "rt-1", seq: 1, payload: [:])))
        #expect(state.activity == .thinking)
    }
}
