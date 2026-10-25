import Foundation
import CoreGraphics
import Testing
@testable import Nollie
@testable import NollieCore

// The new conversation screen's pure parts and the engine under it with 10,000 rows. See
// Docs/specs/conversation-ui.md.

@Suite struct ConversationFollowTests {
    @Test func startsFollowingAndOnlyThePersonLeavesIt() {
        var follow = ConversationFollow()
        #expect(follow.isFollowing)
        // A small nudge is still the bottom.
        follow.personScrolled(distanceFromBottom: 40)
        #expect(follow.isFollowing)
        follow.personScrolled(distanceFromBottom: 300)
        #expect(follow.mode == .reading)
        // Scrolling back down does not follow until the list rests.
        follow.personScrolled(distanceFromBottom: 10)
        #expect(follow.mode == .reading)
        follow.cameToRest(distanceFromBottom: 10, atNewestEnd: true)
        #expect(follow.isFollowing)
    }

    @Test func restingAtTheBottomOfAnOlderWindowKeepsReading() {
        var follow = ConversationFollow()
        follow.personScrolled(distanceFromBottom: 900)
        // The window dropped its newest rows: the bottom of the list is not the newest row.
        follow.cameToRest(distanceFromBottom: 0, atNewestEnd: false)
        #expect(follow.mode == .reading)
        follow.jumpToNewest()
        #expect(follow.isFollowing)
    }
}

@Suite struct ConversationVisibleSpanTests {
    @Test func aStrayRowFarAwayDoesNotStretchTheSpan() {
        #expect(ConversationFollow.visibleSpan([38, 39, 40, 41, 43, 44, 126]) == 38...44)
        #expect(ConversationFollow.visibleSpan([2, 120, 121, 122, 123]) == 120...123)
        #expect(ConversationFollow.visibleSpan([7]) == 7...7)
        #expect(ConversationFollow.visibleSpan([]) == nil)
    }
}

@Suite struct ConversationStackTests {
    private func stack(_ ids: [String], width: CGFloat = 390, room: CGFloat = 600) -> ConversationStack {
        var stack = ConversationStack()
        stack.estimate = 100
        stack.set(width: width, room: room)
        stack.set(ids: ids)
        return stack
    }

    @Test func aShortChatRestsOnTheBottom() {
        var short = stack(["a", "b"])
        #expect(short.lead == 400)
        #expect(short.frame(at: 0).minY == 400)
        #expect(short.contentHeight == 600)
        short.measured("b", height: 50)
        #expect(short.frame(at: 1).maxY == 600)
        #expect(short.frame(at: 0).minY == 450)
    }

    @Test func heightsAreKeptByIdAndForgottenForANewWidth() {
        var list = stack((0..<10).map { "r\($0)" })
        list.measured("r3", height: 240)
        // Rows paged in above keep the measured one's height.
        list.set(ids: ["n0", "n1"] + (0..<10).map { "r\($0)" })
        #expect(list.height(of: "r3") == 240)
        #expect(list.frame(at: 5).height == 240)
        list.set(width: 700, room: 600)
        #expect(!list.isMeasured("r3"))
    }

    @Test func findsTheRowsInARangeByBisection() {
        let list = stack((0..<300).map { "r\($0)" })
        #expect(list.indices(from: 0, to: 100) == 0..<1)
        #expect(list.indices(from: 150, to: 450) == 1..<5)
        #expect(list.indices(from: 29_950, to: 40_000) == 299..<300)
    }

    /// Rows paged in above the row at the top of the screen leave it at the same height on screen.
    @Test func theAnchorRowStaysWhereItWasWhenRowsArriveAbove() {
        var list = stack((100..<200).map { "r\($0)" })
        let visibleTop: CGFloat = 4_050
        let anchor = ConversationAnchor.find(in: list, visibleTop: visibleTop)
        #expect(anchor == ConversationAnchor(id: "r140", offset: -50))
        list.set(ids: (0..<200).map { "r\($0)" })
        let top = anchor?.visibleTop(in: list)
        #expect(top == 14_050)
        #expect(ConversationAnchor.find(in: list, visibleTop: top ?? 0) == anchor)
    }

    @Test func onlyGrowthAboveTheScreenMovesTheOffset() {
        // A row measured for the first time across the top edge grows upward.
        #expect(ConversationStack.offsetAdjustment(itemTop: 900, itemBottom: 1_000, delta: 40, firstMeasure: true, visibleTop: 950) == 40)
        // A reply growing that the person is reading grows at its end.
        #expect(ConversationStack.offsetAdjustment(itemTop: 900, itemBottom: 1_000, delta: 40, firstMeasure: false, visibleTop: 950) == 0)
        #expect(ConversationStack.offsetAdjustment(itemTop: 800, itemBottom: 900, delta: 40, firstMeasure: false, visibleTop: 950) == 40)
        // Below the top of the screen nothing moves.
        #expect(ConversationStack.offsetAdjustment(itemTop: 1_200, itemBottom: 1_300, delta: 40, firstMeasure: true, visibleTop: 950) == 0)
    }
}

@Suite struct ConversationListItemsTests {
    private func user(_ id: String) -> ConversationRow { ConversationRow(id: id, kind: .user(text: id, delivery: .sent)) }
    private func bot(_ id: String) -> ConversationRow {
        ConversationRow(id: id, kind: .assistant(ConversationReply(text: id, reasoning: "", ending: .complete)))
    }

    @Test func cardsAndTheActivityLineFollowTheNewestRowOnly() {
        let card = ConversationCard(id: "c1", method: "approval", kind: .approval(requestId: nil, command: "ls", description: nil, choices: []), shownAt: 0)
        let rows = [user("u1"), bot("b1"), user("u2"), user("u2")]
        let items = ConversationListItem.make(transcript: rows, cards: [card], activity: "Thinking", atNewestEnd: true)
        #expect(items.map(\.id) == ["u1", "b1", "u2", "card:c1", "activity"])
        #expect(items[2] == .row(user("u2"), startsTurn: true))
        #expect(items[0] == .row(user("u1"), startsTurn: false))
        let older = ConversationListItem.make(transcript: rows, cards: [card], activity: "Thinking", atNewestEnd: false)
        #expect(older.map(\.id) == ["u1", "b1", "u2"])
    }

    @Test func aGrowingReplyIsAChangeNotANewOrder() {
        let before = ConversationListItem.make(transcript: [user("u1"), bot("b")], cards: [], activity: nil, atNewestEnd: true)
        var longer = bot("b")
        longer.kind = .assistant(ConversationReply(text: "b and more", reasoning: "", ending: nil))
        let after = ConversationListItem.make(transcript: [user("u1"), longer], cards: [], activity: nil, atNewestEnd: true)
        let change = ConversationListChange(from: before, to: after)
        #expect(change.sameOrder)
        #expect(change.changed == ["b"])
        #expect(ConversationListChange(from: after, to: after).isEmpty)
    }
}

@Suite struct ConversationReplyBlocksTests {
    @Test func splitsProseAndFencedCode() {
        let text = "Here it is:\n\n```bash\nls -la\necho hi\n```\n\nThat lists them."
        #expect(ConversationReplyBlocks.parse(text) == [
            .text("Here it is:"), .code(language: "bash", "ls -la\necho hi"), .text("That lists them."),
        ])
    }

    /// A single line break inside a paragraph reads as a space, as in Markdown; lists and bold lead-ins keep
    /// their lines, and a blank line still ends the paragraph.
    @Test func softBreaksJoinButListsKeepTheirLines() {
        #expect(ConversationReplyBlocks.parse("Here is the\ncommand I want to run:") == [.text("Here is the command I want to run:")])
        #expect(ConversationReplyBlocks.parse("Two causes:\n\n1. One\n2. Two\n- three") == [.text("Two causes:\n\n1. One\n2. Two\n- three")])
        #expect(ConversationReplyBlocks.parse("**Day 1.** Walk.\n**Day 2.** Rest.") == [.text("**Day 1.** Walk.\n**Day 2.** Rest.")])
    }

    @Test func anOpenFenceWhileStreamingRunsToTheEnd() {
        #expect(ConversationReplyBlocks.parse("Try:\n```\nmake che") == [.text("Try:"), .code(language: nil, "make che")])
    }

    @Test func plainTextIsOneBlockAndEmptyIsNone() {
        #expect(ConversationReplyBlocks.parse("Just words.\nTwo lines.") == [.text("Just words. Two lines.")])
        #expect(ConversationReplyBlocks.parse("").isEmpty)
    }
}

@Suite struct ConversationDemoLineageTests {
    @Test func tenThousandRowsInFourSegmentsWithEveryKind() {
        let lineage = ConversationDemoLineage(rows: 10_000)
        #expect(lineage.segments.count == 4)
        #expect(lineage.segments.values.map(\.count).reduce(0, +) == 10_000)
        #expect(lineage.parents == ["demo-s1": "demo-s0", "demo-s2": "demo-s1", "demo-s3": "demo-s2"])
        let rows = lineage.segments.values.flatMap { $0 }
        #expect(Set(rows.map(\.address.rowId)) == Set(1...10_000))
        #expect(rows.contains { $0.role == "tool" })
        #expect(rows.contains { $0.text.contains("```") })
        #expect(rows.contains { !$0.isShown })
    }
}

@MainActor
@Suite struct ConversationEngineAtScaleTests {
    /// A link that answers the attach and nothing else.
    private actor QuietLink: ConversationLink {
        func currentPhase() async -> GatewayPhase { .ready }
        func request(_ method: String, _ params: GatewayJSON, timeout: Duration?) async throws -> GatewayJSON {
            method == "session.resume" ? ["session_id": "rt-scale", "stored_session_id": "demo-s3", "running": false] : [:]
        }
        func answer(question id: String, method: String, result: GatewayJSON) async {}
        func decline(question id: String) async {}
        func watch(session: String, profile: String?) async {}
        func unwatch(session: String) async {}
    }

    private func settled(_ engine: ConversationEngine, _ check: () -> Bool) async {
        for _ in 0..<500 where !check() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// The screen's paging, row by row from the newest to the first and back: the transcript never holds more
    /// than the window's capacity plus the boundaries, and every shown row comes past exactly once each way.
    @Test func walkingTenThousandRowsKeepsTheTranscriptBounded() async {
        let lineage = ConversationDemoLineage(rows: 10_000)
        let history = MemoryConversationHistory(segments: lineage.segments, parents: lineage.parents)
        let engine = ConversationEngine(key: "scale", sessionId: lineage.tip, link: QuietLink(), history: history,
                                        lineageSource: history, store: MemoryConversationCacheStore())
        let clock = ContinuousClock()
        let started = clock.now
        await engine.start()
        await settled(engine) { !engine.transcript.isEmpty }
        print("CONVERSATION-MEASURE engine start to first rows: \(clock.now - started)")
        let newest = engine.transcript.last?.id
        var most = 0
        var seen = Set<String>()
        // Up: show the top row as the screen would while scrolling, until the first row is in.
        for _ in 0..<2_000 {
            most = max(most, engine.transcript.count)
            seen.formUnion(engine.transcript.map(\.id))
            if engine.historyAtOldestEnd { break }
            let before = engine.transcript.first?.id
            engine.showing(row: 0)
            await settled(engine) { engine.transcript.first?.id != before || engine.historyAtOldestEnd }
        }
        seen.formUnion(engine.transcript.map(\.id))
        #expect(engine.historyAtOldestEnd)
        #expect(engine.transcript.first?.id == "stored:demo-s0#1")
        let shown = lineage.segments.values.flatMap { $0 }.filter(\.isShown).count
        // Every shown row, plus one summarized note at each of the three boundaries.
        #expect(seen.count == shown + 3)
        #expect(most <= 300 + 3)

        // Down again, then the jump button's way back.
        engine.showNewest()
        await settled(engine) { engine.historyAtNewestEnd }
        #expect(engine.transcript.last?.id == newest)
        #expect(engine.transcript.count <= 100)
    }

    /// Serves another source's pages, holding back older pages (offset above zero) while `hold` is on.
    private actor GatedHistory: ConversationHistorySource, ConversationLineageSource {
        let inner: MemoryConversationHistory
        var hold = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var held: Int { waiting.count }

        init(_ inner: MemoryConversationHistory) { self.inner = inner }

        func setHold(_ on: Bool) { hold = on }

        func page(segment: String, offset: Int, limit: Int) async throws -> ConversationHistoryPage {
            if hold, offset > 0 { await withCheckedContinuation { waiting.append($0) } }
            return try await inner.page(segment: segment, offset: offset, limit: limit)
        }

        func parent(of segment: String) async throws -> String? { try await inner.parent(of: segment) }

        func release() {
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
        }
    }

    /// The jump button pressed while an older page is on its way: the newest rows come back, and the late page,
    /// when it lands, is dropped rather than put above them.
    @Test func aLatePageAfterTheJumpToNewestIsDropped() async {
        let lineage = ConversationDemoLineage(rows: 10_000)
        let history = GatedHistory(MemoryConversationHistory(segments: lineage.segments, parents: lineage.parents))
        let engine = ConversationEngine(key: "race", sessionId: lineage.tip, link: QuietLink(), history: history,
                                        lineageSource: history, store: MemoryConversationCacheStore())
        await engine.start()
        await settled(engine) { !engine.transcript.isEmpty }
        let newest = engine.transcript.last?.id
        let newestFirst = engine.transcript.first?.id
        // Up far enough that the window drops its newest rows.
        for _ in 0..<6 where engine.historyAtNewestEnd {
            let before = engine.transcript.first?.id
            engine.showing(row: 0)
            await settled(engine) { engine.transcript.first?.id != before }
        }
        #expect(!engine.historyAtNewestEnd)

        // One more page asked for, and held on its way.
        await history.setHold(true)
        let topBefore = engine.transcript.first?.id
        engine.showing(row: 0)
        for _ in 0..<500 where await history.held == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(await history.held == 1)

        // The jump: the newest page comes back at once.
        engine.showNewest()
        await settled(engine) { engine.historyAtNewestEnd && engine.transcript.last?.id == newest }
        #expect(engine.transcript.last?.id == newest)
        #expect(engine.transcript.first?.id == newestFirst)
        let afterJump = engine.transcript.map(\.id)

        // The late page lands: nothing changes.
        await history.release()
        await history.setHold(false)
        try? await Task.sleep(for: .milliseconds(100))
        await engine.settle()
        #expect(engine.transcript.map(\.id) == afterJump, "the late page above \(topBefore ?? "-") was put above the newest rows")
        #expect(engine.historyAtNewestEnd)
        #expect(engine.transcript.count <= 100)
    }
}

