import Foundation
import Testing
@testable import NollieCore

/// What a bot says must always appear as its reply, not hide inside a "Reasoning" card. The echo
/// sent as `reasoning.available` (the reply's first 500 characters) is kept out of that card. When
/// a model delivers its entire answer as reasoning and the gateway promotes it, it is shown as the
/// reply. Genuine thinking ahead of an answer still gets its own card.
@MainActor @Suite struct AnswerOrThinkingTests {
    private static let answerTable = """
    ### Garden shortlist
    | Rank | Plant / Variety | Height | Sun | Best for | Rating |
    |---|---|---|---|---|---|
    | 🥇 | **Sunflower — Giant** | 3m / 2m wide | Full | Tall screens | ⭐⭐⭐⭐⭐ |
    | 🥈 | **Lavender — Hidcote** | 60cm / 50cm wide | Full | Scent and bees | ⭐⭐⭐⭐½ |
    """

    private func feed(_ chat: ChatSession, _ type: String, _ fields: [String: JSONValue] = [:]) {
        chat.handle(event: ChatFixtures.event(for: chat, type, fields))
    }

    /// Sends `text` as a run of `type` events, thirteen characters at a time.
    private func streamDeltas(_ chat: ChatSession, type: String, of text: String) {
        let letters = Array(text)
        for start in stride(from: 0, to: letters.count, by: 13) {
            let piece = String(letters[start..<min(start + 13, letters.count)])
            feed(chat, type, ["text": .string(piece)])
        }
    }

    private func lastReply(_ chat: ChatSession) -> (text: String, reasoning: String?)? {
        chat.items.reversed().lazy.compactMap { item -> (String, String?)? in
            if case .assistant(let text, let reasoning, _) = item.kind { return (text, reasoning) } else { return nil }
        }.first
    }

    // MARK: live turns

    @Test func theGatewaysEchoOfTheReplyIsNotThinking() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        streamDeltas(chat, type: "message.delta", of: Self.answerTable)
        feed(chat, "reasoning.available", ["text": .string(String(Self.answerTable.prefix(500)))])
        feed(chat, "message.complete", ["text": .string(Self.answerTable)])
        let reply = try #require(lastReply(chat))
        #expect(reply.text == Self.answerTable)
        #expect(reply.reasoning == nil)
    }

    @Test func anAnswerSentOnlyAsReasoningBecomesTheReply() throws {
        // Certain models return nothing after a web search. Their reasoning is then treated by the
        // gateway as the answer, which it flags by echoing the same text in message.complete.
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        feed(chat, "thinking.delta", ["text": "(waiting for the model)"])
        streamDeltas(chat, type: "reasoning.delta", of: Self.answerTable)
        feed(chat, "message.complete", ["text": .string(Self.answerTable), "reasoning": .string(Self.answerTable)])
        let reply = try #require(lastReply(chat))
        #expect(reply.text == Self.answerTable)
        #expect(reply.reasoning == nil)
    }

    @Test func thinkingAheadOfAnAnswerSentAsReasoningKeepsOnlyTheThinking() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        feed(chat, "reasoning.delta", ["text": "Sort the plants by height, then by sun.\n\n"])
        streamDeltas(chat, type: "reasoning.delta", of: Self.answerTable)
        feed(chat, "message.complete", ["text": .string(Self.answerTable), "reasoning": .string(Self.answerTable)])
        let reply = try #require(lastReply(chat))
        #expect(reply.text == Self.answerTable)
        #expect(reply.reasoning == "Sort the plants by height, then by sun.")
    }

    @Test func realThinkingBeforeAStreamedAnswerKeepsItsCard() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        feed(chat, "reasoning.delta", ["text": "A table suits a shortlist like this."])
        feed(chat, "thinking.delta", ["text": "(◔_◔) pondering"])
        streamDeltas(chat, type: "message.delta", of: Self.answerTable)
        feed(chat, "reasoning.available", ["text": .string(String(Self.answerTable.prefix(500)))])
        feed(chat, "message.complete", ["text": .string(Self.answerTable)])
        let reply = try #require(lastReply(chat))
        #expect(reply.text == Self.answerTable)
        // Only what the model thought: no spinner line from the gateway, no echo.
        #expect(reply.reasoning == "A table suits a shortlist like this.")
    }

    @Test func aReplyAlreadyShownAsAnInterimMessageIsNotShownAgain() throws {
        // Certain runtimes emit each completed message through message.interim (the last one as well),
        // after which message.complete carries the response_previewed flag.
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        streamDeltas(chat, type: "message.delta", of: Self.answerTable)
        feed(chat, "message.interim", ["text": .string(Self.answerTable), "already_streamed": true])
        feed(chat, "thinking.delta", ["text": ""])
        feed(chat, "message.complete", ["text": .string(Self.answerTable), "response_previewed": true])
        let replies = chat.items.filter { if case .assistant = $0.kind { return true } else { return false } }
        #expect(replies.count == 1)
        #expect(lastReply(chat)?.text == Self.answerTable)
    }

    @Test func aTurnCutOffBeforeAnyAnswerNeverPromotesItsThinking() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        feed(chat, "reasoning.delta", ["text": "Perhaps look it up first"])
        feed(chat, "message.complete", ["text": "", "status": "interrupted"])
        #expect(lastReply(chat) == nil)
    }

    // MARK: the rule itself

    @Test func settlingWhatCountsAsReasoning() {
        let answer = "Three calls before noon."
        // After reconnecting partway through, just the end of the answer arrives as reasoning.
        let tail = String(Self.answerTable.suffix(Self.answerTable.count / 2))
        typealias Case = (streamed: String, thinking: String, final: String, promoted: String?, kept: String?, why: String)
        let cases: [Case] = [
            (answer, answer, answer, nil, answer, "with streamed text, reasoning is real thinking"),
            ("", "Three  calls\nbefore noon. ", answer, nil, nil, "the answer again, spaced differently"),
            ("", "<think>Three calls before noon.</think>", answer, nil, nil, "think tags make no difference"),
            ("", "Look at the diary.", answer, nil, "Look at the diary.", "different reasoning stays"),
            ("", "Three calls before noon. </think> ok", answer, answer, nil, "the promoted mark drops reasoning holding the answer"),
            ("", "", answer, answer, nil, "nothing left"),
            ("", tail, Self.answerTable, Self.answerTable, nil, "the tail of the answer, marked promoted"),
            ("", tail, Self.answerTable, nil, tail, "without the mark a fragment is not assumed to be the answer"),
        ]
        for c in cases {
            let settled = StreamAssembler.settledReasoning(streamedText: c.streamed, reasoning: c.thinking, finalText: c.final, gatewayReasoning: c.promoted)
            #expect(settled == c.kept, "\(c.why)")
        }
    }

    // MARK: stored history

    // Rows as the gateway stores them.
    private func said(by person: String, at time: Double) -> TranscriptMessage {
        TranscriptMessage(role: "user", text: person, timestamp: time, reasoning: nil, apiContent: nil, finishReason: nil, hasToolCalls: false)
    }

    private func toolResult(at time: Double) -> TranscriptMessage {
        TranscriptMessage(role: "tool", text: "results", timestamp: time, reasoning: nil, apiContent: nil, finishReason: nil, hasToolCalls: false)
    }

    private func bot(says words: String = "", thinking: String? = nil, api: String? = nil, finish: String? = nil,
                     askingForTools: Bool = false, at time: Double) -> TranscriptMessage {
        TranscriptMessage(role: "assistant", text: words, timestamp: time, reasoning: thinking, apiContent: api,
                          finishReason: finish, hasToolCalls: askingForTools)
    }

    private func replyTexts(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { item in
            guard case .assistant(let text, _, _) = item.kind else { return nil }
            return text
        }
    }

    @Test func historyShowsAnAnswerStoredWithNoContent() {
        let table = Self.answerTable
        let question = said(by: "list the plants", at: 1)
        // Over REST the answer lives in api_content.
        let page = [question, toolResult(at: 2), bot(thinking: table, api: table, finish: "stop", at: 3)]
        let built = TranscriptItem.fromHistory(page)
        #expect(replyTexts(built) == [table])
        if case .assistant(_, let thinking, _)? = built.last?.kind { #expect(thinking == nil) }

        // session.resume carries no api_content, so use the order: a clean stop, then the person speaks or the chat ends.
        let storedThisWay: [[TranscriptMessage]] = [
            [question, bot(thinking: table, at: 3), said(by: "thanks", at: 4)],
            [question, bot(thinking: table, at: 3)],
        ]
        for history in storedThisWay { #expect(replyTexts(TranscriptItem.fromHistory(history)) == [table]) }
    }

    @Test func historyKeepsThinkingOutOfTheReplies() {
        let ask = said(by: "q", at: 1)
        let notAnswers: [(String, [TranscriptMessage], Bool)] = [
            ("while running the last row may be thinking still", [said(by: "list the plants", at: 1), bot(thinking: "Looking first", at: 2)], true),
            ("followed by the tool it wanted", [ask, bot(thinking: "Better search", at: 2), toolResult(at: 3)], false),
            ("marked as asking for a tool", [ask, bot(thinking: "Better search", askingForTools: true, at: 2)], false),
            ("cut off by length", [ask, bot(thinking: "Half a tho", finish: "length", at: 2)], false),
        ]
        for (why, history, running) in notAnswers {
            #expect(replyTexts(TranscriptItem.fromHistory(history, running: running)).isEmpty, "\(why)")
        }

        // When a row has its own text, differing reasoning stays and reasoning that merely repeats it goes.
        let ordinary = [bot(says: "Done.", thinking: "Done.", at: 1), bot(says: "Sent.", thinking: "Keep it short.", at: 2)]
        let kept = TranscriptItem.fromHistory(ordinary).compactMap { item -> String? in
            guard case .assistant(_, let reasoning, _) = item.kind else { return nil }
            return reasoning ?? "-"
        }
        #expect(kept == ["-", "Keep it short."])
    }

    @Test func aStalledResponseTheGatewayNudgedOnIsNotAReply() {
        // After a stall the gateway appends a "continue" turn. The stalled row has some partial
        // text in api_content, yet it did not end cleanly.
        let history = [said(by: "open the file", at: 1),
                       bot(thinking: "Partial", api: "Partial", finish: "incomplete", at: 2),
                       said(by: "[System: Continue now.]", at: 3),
                       bot(thinking: "It says hello.", api: "It says hello.", finish: "stop", at: 4)]
        #expect(replyTexts(TranscriptItem.fromHistory(history)) == ["It says hello."])
        #expect(TranscriptItem.withPromotedAnswers(history)[1].text == "")
    }

    @Test func anAnswerFinishedHereStaysWhileAnotherTurnBegins() {
        // Another device starts a turn: the snapshot reads running before the prompt is saved.
        let history = [said(by: "list the plants", at: 1), bot(thinking: Self.answerTable, at: 2)]
        let already: Set<String> = [StreamAssembler.normalized(Self.answerTable)]
        let withoutMemory = replyTexts(TranscriptItem.fromHistory(history, running: true))
        let withMemory = replyTexts(TranscriptItem.fromHistory(history, running: true, settled: already))
        #expect(withoutMemory.isEmpty)
        #expect(withMemory == [Self.answerTable])
    }

    @Test func hiddenRowsAndBlankReasoningStayOut() throws {
        var hidden = bot(thinking: "[response interrupted]", at: 2)
        hidden.displayKind = "hidden"
        let promoted = TranscriptItem.withPromotedAnswers([said(by: "q", at: 1), hidden])
        #expect(promoted[1].text == "")
        let json = #"{"role":"assistant","content":"Finished.","reasoning_content":" "}"#
        #expect(try JSONDecoder().decode(TranscriptMessage.self, from: Data(json.utf8)).reasoning == nil)
    }

    @Test func previewsAndSummariesSeeThePromotedAnswer() {
        let history = [said(by: "list the plants", at: 1), bot(thinking: Self.answerTable, api: Self.answerTable, at: 2)]
        let texts = TranscriptItem.withPromotedAnswers(history).map(\.text)
        #expect(texts == ["list the plants", Self.answerTable])
    }

    @Test func storedRowsDecodeFromEitherSpellingAndSurviveTheCache() throws {
        func decode(_ json: String) throws -> TranscriptMessage { try JSONDecoder().decode(TranscriptMessage.self, from: Data(json.utf8)) }
        let direct = try decode(#"{"role":"assistant","content":"","api_content":"Result","finish_reason":"stop","reasoning_content":"Result","tool_calls":[]}"#)
        #expect([direct.apiContent, direct.finishReason, direct.reasoning] == ["Result", "stop", "Result"])
        #expect(direct.hasToolCalls == false)

        let raw = #"{"role":"assistant","content":"","api_content":"B","tool_calls":[{"function":{"name":"web_search"}}]}"#
        let viaValue = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)).decode(TranscriptMessage.self)
        #expect(viaValue.apiContent == "B" && viaValue.hasToolCalls && viaValue.name == "web_search")

        // Encoding for the transcript cache and decoding it back loses nothing.
        let cached = try JSONEncoder().encode(viaValue)
        let again = try JSONDecoder().decode(TranscriptMessage.self, from: cached)
        #expect(again.apiContent == "B" && again.hasToolCalls)
    }
}
