import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

/// How the view diffs the thread's rows. When a token arrives in the newest reply, the older
/// rows (and what they render with) must stay equal to before, since that equality is what stops
/// a long history from being evaluated all over again for every token.
@Suite struct ThreadRowStabilityTests {
    private typealias Rows = TestRows

    /// `pairs` question and answer rows; the last answer is the one still streaming.
    private func conversation(pairs: Int, lastAnswer: String) -> [TranscriptItem] {
        var thread: [TranscriptItem] = []
        for n in 0..<pairs {
            let at = Double(n) * 30
            var question = Rows.user("q\(n)", "ask \(n)", at: at)
            question.rowID = n * 2
            var answer = Rows.reply("r\(n)", n == pairs - 1 ? lastAnswer : "reply \(n)", streaming: n == pairs - 1, at: at + 5)
            answer.rowID = n * 2 + 1
            thread += [question, answer]
        }
        return thread
    }

    @MainActor private func rowContext(lastID: String?, actions: RowActions) -> RowContext {
        let verbose = true, compact = false
        return RowContext(profile: "studio", bot: "studio", typingTool: nil, showReasoning: verbose, currentStepOnly: compact,
                          showStats: compact, interruptCause: nil, lastID: lastID, openReasoning: [], openTools: ["t1"],
                          showToolOutput: verbose, compactTools: compact, wide: compact, maxBubble: 320, actions: actions)
    }

    @MainActor @Test func aTokenInTheLastReplyLeavesEarlierRowsAndTheirContextEqual() {
        let now = Date(timeIntervalSince1970: 1_800_010_000)
        let before = TranscriptRowModel.build(conversation(pairs: 40, lastAnswer: "The cache is"), now: now)
        let after = TranscriptRowModel.build(conversation(pairs: 40, lastAnswer: "The cache is cold"), now: now)
        let sizes: [Int] = [before.count, after.count]
        #expect(sizes == [80, 80])

        let boundary = TranscriptRowModel.split(count: before.count, tailFrom: nil)
        #expect((1..<before.count).contains(boundary), "a thread this size should have lazy rows and a tail")
        #expect(before.prefix(boundary).elementsEqual(after.prefix(boundary)), "older rows changed")
        #expect(before.suffix(from: boundary).map(\.id) == after.suffix(from: boundary).map(\.id))
        #expect(before.last != after.last, "the streaming reply itself did change")

        // The actions object lives as long as the view, so contexts built around it compare equal.
        let shared = RowActions()
        let sameAgain = rowContext(lastID: "r39", actions: shared) == rowContext(lastID: "r39", actions: shared)
        let newLast = rowContext(lastID: "r39", actions: shared) == rowContext(lastID: "r40", actions: shared)
        let newActions = rowContext(lastID: "r39", actions: shared) == rowContext(lastID: "r39", actions: RowActions())
        #expect(sameAgain)
        #expect(!newLast, "a new last row is a change: the bot sits beside it")
        #expect(!newActions, "a fresh actions object is why the view keeps one")
    }

    @Test func theTailMovesInWholeBlocksAndTheThreadsOwnBoundaryHoldsWhileSensible() {
        let block = TranscriptRowModel.tailBlock, cap = TranscriptRowModel.tailCap
        let tailStarts: [(Int, Int)] = [(block - 1, 0), (block * 2, block), (block * 2 + 5, block)]
        for (count, start) in tailStarts { #expect(TranscriptRowModel.tailStart(count) == start, "count \(count)") }

        let splits: [(count: Int, own: Int, expected: Int, why: String)] = [
            (block * 3, block, block, "the thread's own boundary stands while the tail beyond it is within the cap"),
            (block + cap + 1, block, TranscriptRowModel.tailStart(block + cap + 1), "past the cap the blocks take over"),
            (block * 4, block * 3 + 2, TranscriptRowModel.tailStart(block * 4), "a boundary beyond where the blocks would begin is not honoured"),
            // Sixty tool rows in one turn stream without the boundary shifting: rows that crossed it
            // mid-turn were placed using the lazy stack's estimates, overlapping their neighbours.
            (block + 60, block, block, "a long turn of tool calls"),
        ]
        for entry in splits { #expect(TranscriptRowModel.split(count: entry.count, tailFrom: entry.own) == entry.expected, "\(entry.why)") }
    }

    /// A tool call that the gateway delivers twice yields two items sharing an id. They must remain
    /// two rows, each with an id of its own, because rows with one id can be laid out over each other.
    @Test func noTwoRowsShareAnID() {
        let thread = [Rows.user("q", "start"), Rows.tool("tool-dup"), Rows.tool("tool-dup"), Rows.reply("r", "finished")]
        let rows = TranscriptRowModel.build(thread, now: Rows.epoch)
        #expect(Set(rows.map(\.id)).count == rows.count && rows.count == 4)
        #expect(rows.map(\.kindTag) == ["user", "tool", "tool", "reply"])
        #expect(rows.dropFirst().first?.id == "tool-dup", "the first of the pair keeps the id")
    }

    /// Tool calls in a turn fold into the first call's row, which holds the whole run. A reply or
    /// a long pause starts a new run, and a message to another bot is never folded. With folding
    /// off the rows are untouched.
    @MainActor @Test func aTurnsToolCallsFoldIntoOneRow() {
        var relay = ToolActivity(id: "relay", name: "message_agent", status: .done)
        relay.delivery = BotDelivery(target: "career", message: "hello")
        let thread: [TranscriptItem] = [
            Rows.user("q", "start"),
            Rows.tool("c1", status: .done, at: 1), Rows.tool("c2", status: .done, at: 2), Rows.tool("c3", status: .done, at: 3),
            Rows.reply("mid", "so far", at: 4),
            Rows.tool("c4", status: .done, at: 5),
            TranscriptItem(id: "relay", kind: .tool(relay), timestamp: Rows.epoch.addingTimeInterval(6)),
            Rows.tool("c5", status: .done, at: 7), Rows.tool("c6", status: .done, at: 3000),
            Rows.reply("end", "all done", at: 3001),
        ]

        let plain = TranscriptRowModel.build(thread, now: Rows.epoch)
        #expect(plain.count == thread.count)
        #expect(plain.allSatisfy { $0.run.isEmpty })

        let folded = TranscriptRowModel.build(thread, now: Rows.epoch, foldSteps: true)
        #expect(folded.map(\.id) == ["q", "c1", "mid", "c4", "relay", "c5", "c6", "end"])
        let runs = folded.map { $0.run.map(\.id) }
        #expect(runs == [[], ["c1", "c2", "c3"], [], ["c4"], [], ["c5"], ["c6"], []],
                "one call alone is a run too; a message to another bot keeps its own notice; a long pause starts a new run")
        #expect(folded[6].separator != nil)
        #expect(ToolRunRow.duration(41.4) == "41s" && ToolRunRow.duration(130) == "2 min")
    }

    /// Just the latest row fades in, and only after the chat has opened. A reply that is streaming
    /// never fades (it inherits the typing bubble's place), and nothing fades while history loads.
    @MainActor @Test func onlyTheNewestRowFadesIn() {
        func newestFades(ending: TranscriptItem, opening: Bool = false) -> Bool {
            let rows = TranscriptRowModel.build([Rows.user("q", "start"), ending], now: Rows.epoch)
            return TranscriptView.enteringRowID(rows, opening: opening) == ending.id
        }
        #expect(newestFades(ending: Rows.tool("newest")))
        #expect(newestFades(ending: Rows.reply("newest", "Hi")))
        #expect(!newestFades(ending: Rows.reply("newest", "Hi", streaming: true)))
        #expect(!newestFades(ending: Rows.reply("newest", "", streaming: true)))
        #expect(!newestFades(ending: Rows.tool("newest"), opening: true))
        #expect(TranscriptView.enteringRowID([], opening: false) == nil)
    }

    @MainActor @Test func aStreamingReplyHoldsTheTypingBubbleUntilItIsWhole() throws {
        let suite = "nollie.typing-bubble-tests.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { Issue.record("no scratch defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let long = String(repeating: "Everything comes at once.\n\n", count: 12)

        func drawnHeight(_ text: String, streaming: Bool, aged seconds: TimeInterval = 0, thinking: String? = nil) throws -> Int {
            let item = TranscriptItem(id: "answer", kind: .assistant(text: text, reasoning: thinking, streaming: streaming),
                                      timestamp: Date().addingTimeInterval(-seconds))
            let row = TranscriptRow(item: item, showStats: false)
            let picture = ImageRenderer(content: row.frame(width: 360).fixedSize(horizontal: false, vertical: true).defaultAppStorage(defaults))
            return try #require(picture.cgImage).height
        }

        let typing = try drawnHeight("", streaming: true)
        #expect(typing > 0, "dots show while waiting")
        let sameDots = try [drawnHeight("Ev", streaming: true), drawnHeight(long, streaming: true, aged: 45)]
        #expect(sameDots == [typing, typing], "even after 45 seconds the dots stay")
        #expect(try drawnHeight(long, streaming: false) > typing, "the finished reply takes its full height")

        let note = "Weighing the options first."
        let withThinking = try drawnHeight("", streaming: true, thinking: note)
        #expect(withThinking > typing, "the reasoning disclosure remains")
        #expect(try drawnHeight(long, streaming: true, thinking: note) == withThinking, "streamed words leave the reasoning and typing layout alone")
    }

    @MainActor @Test func aReplyIsAnnouncedOnceWhenComplete() {
        typealias Kind = TranscriptItem.Kind
        let partial: Kind = .assistant(text: "The first", reasoning: nil, streaming: true)
        let whole: Kind = .assistant(text: "The first and last.", reasoning: nil, streaming: false)
        let blank: Kind = .assistant(text: "", reasoning: nil, streaming: false)
        let cutShort: Kind = .assistant(text: "Operation interrupted.", reasoning: nil, streaming: false)
        let fromUser: Kind = .user(text: "Hi", attachments: [])

        let cases: [(Kind, Kind, String?, String)] = [
            (partial, whole, "The first and last.", "completing announces the reply"),
            (partial, partial, nil, "half a reply is never announced"),
            (whole, whole, nil, "an update after the end does not repeat it"),
            (partial, blank, nil, "an empty ending says nothing"),
            (partial, cutShort, nil, "the gateway's cut-short sentence is a card, not a reply"),
            (fromUser, whole, nil, "loading a stored reply is no arrival"),
        ]
        for (old, new, said, why) in cases { #expect(ReplyArrival.announcement(from: old, to: new) == said, "\(why)") }
    }
}
