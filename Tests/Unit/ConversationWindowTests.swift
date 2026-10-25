import Foundation
import Testing
@testable import NollieCore

// The paging window over a lineage's stored history, and its cache. See "The endless main chat" in
// Docs/specs/conversation-engine.md.

/// A pretend Hermes history: stored rows per segment, served newest first by offset as `/messages` does, and each
/// segment's parent. Counts what it was asked.
actor CWFakeHistory: ConversationHistorySource, ConversationLineageSource {
    private var segments: [String: [ConversationHistoryRow]]
    private let parents: [String: String]
    private(set) var pageCalls = 0
    private(set) var parentCalls = 0
    private var refuse = false

    init(segments: [String: [ConversationHistoryRow]], parents: [String: String] = [:]) {
        self.segments = segments
        self.parents = parents
    }

    func page(segment: String, offset: Int, limit: Int) async throws -> ConversationHistoryPage {
        pageCalls += 1
        if refuse { throw GatewayCallFailure.closed }
        let newestFirst = (segments[segment] ?? []).sorted { $0.address.rowId > $1.address.rowId }
        let slice = Array(newestFirst.dropFirst(offset).prefix(limit))
        return ConversationHistoryPage(rows: slice.reversed(), reachedStart: slice.count < limit)
    }

    func parent(of segment: String) async throws -> String? {
        parentCalls += 1
        if refuse { throw GatewayCallFailure.closed }
        return parents[segment]
    }

    func append(_ row: ConversationHistoryRow) { segments[row.address.segment, default: []].append(row) }
    func refuseEverything() { refuse = true }
}

/// Rows `ids` of `segment`, alternating the person and the bot.
func cwRows(_ segment: String, _ ids: ClosedRange<Int>) -> [ConversationHistoryRow] {
    ids.map { id in
        ConversationHistoryRow(address: ConversationRowAddress(segment: segment, rowId: id), role: id.isMultiple(of: 2) ? "assistant" : "user",
                               text: "message \(id)")
    }
}

/// A lineage of four segments (three compressions) holding `perSegment` rows each, ids counting up across them.
private func cwBigLineage(perSegment: Int) -> (CWFakeHistory, [String]) {
    let names = ["s0", "s1", "s2", "s3"]
    var segments: [String: [ConversationHistoryRow]] = [:]
    for (index, name) in names.enumerated() {
        segments[name] = cwRows(name, (index * perSegment + 1)...((index + 1) * perSegment))
    }
    return (CWFakeHistory(segments: segments, parents: ["s3": "s2", "s2": "s1", "s1": "s0"]), names)
}

private func cwIds(_ rows: [ConversationHistoryRow]) -> [Int] { rows.map(\.address.rowId) }

@Suite struct ConversationWindowPagingTests {
    @Test func tenThousandRowsComeBackInOrderWithMemoryBounded() async throws {
        let (history, names) = cwBigLineage(perSegment: 2500)
        let store = MemoryConversationCacheStore()
        let configuration = ConversationWindow.Configuration(pageSize: 100, capacity: 300)
        let window = ConversationWindow(key: "big", lineage: ConversationLineage(tip: "s3"), store: store, source: history,
                                        lineageSource: history, configuration: configuration)
        try await window.refreshNewest()
        #expect(cwIds(await window.rows) == Array(9901...10000))

        // Up to the very first row, one page at a time.
        var seen = cwIds(await window.rows)
        var steps = 0
        while !(await window.atOldestEnd) {
            let top = await window.rows.first!.address.rowId
            try await window.loadOlder()
            let rows = await window.rows
            #expect(rows.count <= configuration.capacity, "the window grew to \(rows.count)")
            #expect(cwIds(rows) == cwIds(rows).sorted(), "rows out of order")
            seen = cwIds(rows).filter { $0 < top } + seen
            steps += 1
            try #require(steps < 200, "the walk does not end")
        }
        #expect(seen == Array(1...10000), "every row once, in order")
        #expect(await window.lineage.segments == names)
        #expect(await window.lineage.rootKnown)
        #expect(await !window.atNewestEnd)
        let pagesUp = await history.pageCalls
        #expect(pagesUp <= 110, "fetched \(pagesUp) pages for 100 pages of rows")

        // Back down to the newest row: every page from the cache.
        var below = cwIds(await window.rows)
        steps = 0
        while !(await window.atNewestEnd) {
            let bottom = await window.rows.last!.address.rowId
            try await window.loadNewer()
            let rows = await window.rows
            #expect(rows.count <= configuration.capacity)
            below += cwIds(rows).filter { $0 > bottom }
            steps += 1
            try #require(steps < 200, "the walk does not end")
        }
        #expect(below == Array(1...10000))
        #expect(await history.pageCalls == pagesUp, "scrolling back down asked Hermes again")
    }

    @Test func aSecondOpenReadsTheCacheBeforeHermes() async throws {
        let (history, _) = cwBigLineage(perSegment: 250)
        let store = MemoryConversationCacheStore()
        let configuration = ConversationWindow.Configuration(pageSize: 100, capacity: 300)
        let first = ConversationWindow(key: "main", lineage: ConversationLineage(tip: "s3"), store: store, source: history,
                                       lineageSource: history, configuration: configuration)
        try await first.refreshNewest()
        while !(await first.atOldestEnd) { try await first.loadOlder() }

        // A new launch: Hermes is out of reach, and everything still scrolls from the cache.
        let offline = CWFakeHistory(segments: [:])
        await offline.refuseEverything()
        let second = ConversationWindow(key: "main", lineage: ConversationLineage(tip: "s3"), store: store, source: offline,
                                        lineageSource: offline, configuration: configuration)
        #expect(await second.openFromCache())
        #expect(cwIds(await second.rows) == Array(901...1000))
        var seen = cwIds(await second.rows)
        var steps = 0
        while !(await second.atOldestEnd) {
            let top = await second.rows.first!.address.rowId
            try await second.loadOlder()
            seen = cwIds(await second.rows).filter { $0 < top } + seen
            steps += 1
            try #require(steps < 50)
        }
        #expect(seen == Array(1...1000))
        #expect(await offline.pageCalls == 0)
        #expect(await offline.parentCalls == 0)
        #expect(await second.networkPages == 0)
        #expect(await second.cachePages > 0)
    }

    @Test func prefetchLoadsAheadOfTheScroll() async throws {
        let (history, _) = cwBigLineage(perSegment: 500)
        let window = ConversationWindow(key: "prefetch", lineage: ConversationLineage(tip: "s3"), store: MemoryConversationCacheStore(),
                                        source: history, lineageSource: history,
                                        configuration: ConversationWindow.Configuration(pageSize: 100, capacity: 300, prefetchMargin: 40))
        try await window.refreshNewest()
        await window.prefetch(around: 60)
        #expect(await window.rows.count == 100, "not near the top yet")
        await window.prefetch(around: 30)
        #expect(await window.rows.count == 200)
        #expect(await window.rows.first?.address.rowId == 1801)
    }

    @Test func newRowsAtTheTipShiftNoRowOutOfTheWalk() async throws {
        let history = CWFakeHistory(segments: ["s0": cwRows("s0", 1...250)])
        let window = ConversationWindow(key: "growing", lineage: ConversationLineage(tip: "s0"), store: MemoryConversationCacheStore(),
                                        source: history, configuration: ConversationWindow.Configuration(pageSize: 100, capacity: 300))
        try await window.refreshNewest()
        // Thirty new rows land before the next page is asked for: Hermes's offsets move under the walk.
        for row in cwRows("s0", 251...280) { await history.append(row) }
        while !(await window.atOldestEnd) { try await window.loadOlder() }
        #expect(cwIds(await window.rows) == Array(1...250))
        let added = try await window.refreshNewest()
        #expect(cwIds(added) == Array(251...280))
        #expect(cwIds(await window.rows) == Array(1...280))
    }
}

@Suite struct ConversationCacheTests {
    @Test func anotherFormatIsIgnoredAndCleared() async throws {
        let store = MemoryConversationCacheStore()
        let folder = ConversationCache.folderName(for: "old")
        store.plant("\(folder)/manifest.json", Data(#"{"version":0,"segments":{},"nextChunk":9}"#.utf8))
        store.plant("\(folder)/c-1.json", Data("stale".utf8))
        let history = CWFakeHistory(segments: ["s0": cwRows("s0", 1...5)])
        let window = ConversationWindow(key: "old", lineage: ConversationLineage(tip: "s0"), store: store, source: history)
        #expect(await !window.openFromCache())
        #expect(!store.names.contains("\(folder)/c-1.json"))
        try await window.refreshNewest()
        #expect(cwIds(await window.rows) == Array(1...5))
        let manifest = try #require(try store.read("\(folder)/manifest.json"))
        #expect(try JSONDecoder().decode(ConversationCache.Manifest.self, from: manifest).version == ConversationCache.formatVersion)
    }

    @Test func filesGoUnderTheirOwnFolderAndComeBack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nollie-conversation-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileConversationCacheStore(root: root)
        try store.write("a-1/manifest.json", Data("one".utf8))
        try store.write("a-1/c-1.json", Data("two".utf8))
        #expect(try store.read("a-1/manifest.json") == Data("one".utf8))
        #expect(try store.read("a-1/missing.json") == nil)
        try store.removeAll(under: "a-1")
        #expect(try store.read("a-1/c-1.json") == nil)
    }

    @Test func folderNamesAreSafeAndDistinct() {
        let one = ConversationCache.folderName(for: "home/default/main")
        let two = ConversationCache.folderName(for: "home:default:main")
        #expect(one != two)
        #expect(!one.contains("/"))
    }

    @Test func theSavedOutboxComesBackWithSendsInDoubt() async {
        let store = MemoryConversationCacheStore()
        let history = CWFakeHistory(segments: [:])
        let first = ConversationWindow(key: "box", lineage: ConversationLineage(tip: "s0"), store: store, source: history)
        await first.save(outbox: ConversationOutbox(entries: [
            .init(id: "out-1", text: "going", state: .sending), .init(id: "out-2", text: "later"),
            .init(id: "out-3", text: "done", state: .sent),
        ]))
        let second = ConversationWindow(key: "box", lineage: ConversationLineage(tip: "s0"), store: store, source: history)
        #expect(await second.savedOutbox?.entries == [.init(id: "out-1", text: "going", state: .uncertain), .init(id: "out-2", text: "later")])
    }

    @Test func storedRowsReadEitherShapeHermesUses() throws {
        let raw: GatewayJSON = [
            "messages": [
                ["id": 3, "role": "tool", "content": "/var/log 41G", "tool_name": "terminal", "tool_call_id": "c1", "timestamp": 1_760_000_000],
                ["id": 2, "role": "assistant", "content": [["type": "text", "text": ""]], "tool_calls": [["id": "c1", "function": ["name": "terminal"]]],
                 "timestamp": "2026-10-03T12:00:00"],
                ["id": 1, "role": "user", "content": "How full is the disk?"],
                ["id": 4, "role": "system", "content": "hidden"],
            ],
        ]
        let rows = (raw["messages"]?.arrayValue ?? []).compactMap { ConversationHistoryRow(stored: $0, segment: "s0") }
        #expect(rows.map(\.address.rowId) == [3, 2, 1, 4])
        #expect(rows[0].row().kind == .tool(ConversationToolStep(toolId: "c1", name: "terminal", done: true, resultText: "/var/log 41G")))
        #expect(rows[1].calledTools == ["terminal"])
        #expect(rows[1].timestamp != nil)
        #expect(rows.map(\.isShown) == [true, false, true, false])
    }
}
